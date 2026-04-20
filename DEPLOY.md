# Lumera Web Export — Deploy

Documentação da arquitetura de deploy híbrida (Vercel + Cloudflare R2) usada para contornar o limite de 100MB por arquivo do Vercel.

## Arquitetura

```
Browser ──► Vercel              (HTML/JS/WASM/imagens, shell leve ~38MB)
        └─► Cloudflare R2       (index.pck, ~216MB)
```

- **Vercel** hospeda o shell estático do jogo (HTML/JS/WASM/imagens).
- **Cloudflare R2** hospeda o `index.pck` — não cabe nos 100MB de limite do Vercel.
- No runtime, o browser baixa o shell do Vercel e, via `mainPack` config do Godot, baixa o `.pck` direto do R2.

## Por que Cloudflare R2

- **Egress zero** — bandwidth ilimitado sem cobrança (vs ~$90/TB na AWS S3).
- **10GB de storage grátis** por mês.
- **CORS configurável** — permite o browser fazer fetch cross-origin.
- **CDN global** da Cloudflare em todas as edges.
- **Custo em produção:** $0/mês até 10M reads/mês (cada carregamento do jogo = 1 read).

## Distribuição de arquivos

Tudo neste diretório é **gerado pelo export Web do Godot**. A divisão de onde cada arquivo vai no deploy é:

| Arquivo | Tamanho aprox. | Destino | Motivo |
|---|---|---|---|
| `index.html` | 7.7KB | **Vercel** (repo) | Entry point — servido na raiz do domínio |
| `index.js` | 280KB | **Vercel** (repo) | Engine do Godot |
| `index.wasm` | 35MB | **Vercel** (repo) | Binário WebAssembly da engine |
| `index.png` | 1.8MB | **Vercel** (repo) | Splash screen |
| `index.icon.png` | 1.8MB | **Vercel** (repo) | Favicon |
| `index.apple-touch-icon.png` | 66KB | **Vercel** (repo) | Ícone iOS |
| `index.audio.worklet.js` | 7.3KB | **Vercel** (repo) | Worklet de áudio |
| `index.audio.position.worklet.js` | 3KB | **Vercel** (repo) | Worklet de áudio posicional |
| `index.pck` | **216MB** | **Cloudflare R2** | Pacote de assets do jogo — não cabe no Vercel |
| `DEPLOY.md` | — | **Vercel** (repo) | Esta documentação |
| `update-pck-version.sh` | — | **Vercel** (repo) | Script de cache-busting (injeta ETag do pck no `index.html`) |
| `.gitignore`, `.vercelignore` | — | **Vercel** (repo) | Configuração de ignore |

### Resumindo
- **Repo (GitHub → Vercel):** todos os arquivos **exceto** `index.pck`.
- **Cloudflare R2:** **apenas** o `index.pck`.

## Fluxo completo (export → deploy)

```
1. Godot → Project → Export → Web → Export Project
      ↓ gera/atualiza todos os arquivos deste diretório
2. Reaplicar customização no index.html (GODOT_PCK_URL + mainPack)
      ↓ Godot sobrescreve o index.html a cada export
3. wrangler r2 object put lumera-assets/index.pck ...
      ↓ sobe o pck pra R2
4. ./update-pck-version.sh
      ↓ injeta ?v=<etag> no GODOT_PCK_URL (cache-busting no browser)
5. git commit + git push
      ↓ atualiza o repo (sem o pck)
6. vercel --prod
      ↓ publica o shell no Vercel
```

⚠️ **Atenção:** a cada reexportação do Godot, o `index.html` é **regenerado do zero**, perdendo a customização (`GODOT_PCK_URL` e `mainPack`). Sempre reaplicar antes do deploy — ver **"Atualizar o jogo"** abaixo.

## Histórico de tentativas

1. ❌ Deploy completo no Vercel — bloqueado pelo limite de 100MB/arquivo.
2. ❌ GitHub Releases — hospedagem funcionou mas não envia header `Access-Control-Allow-Origin`, bloqueado por CORS.
3. ✅ Cloudflare R2 — resolve ambos: sem limite de tamanho E com CORS configurável.

## Alterações no repositório

### `index.html`

Adicionada variável `GODOT_PCK_URL` (com query string de versão `?v=<etag>` para cache-busting no browser) e campo `mainPack` no `GODOT_CONFIG` para apontar o engine do Godot à URL externa do pck:

```js
const GODOT_PCK_URL = "https://pub-932401cb337444cf95fc203c447835ce.r2.dev/index.pck?v=<etag-do-pck-no-R2>";
const GODOT_CONFIG = { ..., "mainPack": GODOT_PCK_URL };
```

O `?v=<etag>` força browser/CDN a tratar cada pck novo como URL distinta — sem isso, usuários com pck antigo em cache podem pegar binário defasado (R2 não manda `Cache-Control`, então o browser decide heuristicamente por `Last-Modified`, cacheando por minutos/horas).

O campo `fileSizes.index.pck` também foi atualizado para o tamanho real em bytes — usado pela barra de progresso de loading.

### `.gitignore`

Adicionado `index.pck` para garantir que o arquivo nunca seja commitado (GitHub rejeita >100MB em repos normais).

```
.vercel
.env*.local
index.pck
```

### `.vercelignore`

**Necessário** — o Vercel CLI **não respeita** `.gitignore` automaticamente. Sem este arquivo, `vercel deploy` tenta subir o `index.pck` local (se existir no diretório) e falha com "File size limit exceeded".

```
index.pck
.env*.local
```

## Configuração Cloudflare R2

### Bucket
- **Nome:** `lumera-assets`
- **Location:** Automatic
- **URL pública:** `https://pub-932401cb337444cf95fc203c447835ce.r2.dev`

### CORS Policy

Configurada no bucket via **Settings → CORS Policy**:

```json
[
  {
    "AllowedOrigins": ["*"],
    "AllowedMethods": ["GET", "HEAD"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["Content-Length", "Content-Range", "ETag"],
    "MaxAgeSeconds": 3600
  }
]
```

Após estabilizar, recomenda-se restringir `AllowedOrigins` aos domínios finais:
```json
["https://lumera-rpg-online-v02.vercel.app", "https://lumeraonline.com"]
```

## Procedimento de deploy

### Passo 0 — Exportar do Godot
No editor do Godot:

1. Menu **Project → Export**
2. Selecione o preset **Web**
3. Clique **Export Project** → salve **no diretório deste repo** (`c:\Dev\lumera-web-export-v2\`)
4. Confirme sobrescrever os arquivos existentes

Isso gera/atualiza todos os arquivos `index.*` (HTML, JS, WASM, PCK, imagens, worklets).

### Passo 1 — Reaplicar customização no `index.html`
O Godot sobrescreve o `index.html` a cada export, então é preciso **reaplicar manualmente**:

No bloco `<script>` antes do `engine.startGame()`, substituir a linha:

```js
const GODOT_CONFIG = {"args":[],...};
```

Por:

```js
const GODOT_PCK_URL = "https://pub-932401cb337444cf95fc203c447835ce.r2.dev/index.pck";
const GODOT_CONFIG = {"args":[],...,"mainPack":GODOT_PCK_URL};
```

(Adicionar `mainPack` no objeto de config apontando para a URL do pck no R2. O `?v=<etag>` é injetado automaticamente no Passo 3.)

### Passo 2 — Subir o `index.pck` pro R2
```bash
wrangler r2 object put lumera-assets/index.pck --file=./index.pck --remote
```

(Ou via dashboard R2 se o arquivo for <300MB — ver **"Atualizar o jogo"**.)

### Passo 3 — Cache-busting: injetar ETag do pck na URL
Rodar o script helper (Git Bash no Windows, ou bash/WSL):

```bash
./update-pck-version.sh
```

Ele busca o ETag atual do pck no R2 e atualiza o `GODOT_PCK_URL` no `index.html` para `...index.pck?v=<etag>`. Cada pck novo gera um ETag novo → URL nova → browser do usuário ignora cache antigo e baixa o pck novo. Sem isso, usuários podem ficar presos no pck defasado por horas.

Se preferir fazer manual:
```bash
curl -sI https://pub-932401cb337444cf95fc203c447835ce.r2.dev/index.pck | grep -i etag
# copiar o valor entre aspas e colar no ?v=... do index.html
```

### Passo 4 — Atualizar `fileSizes` se o tamanho mudou
```bash
du -b index.pck
```
Copiar o número e atualizar `fileSizes.index.pck` no `index.html`.

### Passo 5 — Commit + push + deploy
```bash
git add index.html
git commit -m "update pck"
git push
vercel --prod
```

## Cache do browser — estratégia simples

Cada camada tem sua estratégia, resolvendo o problema de "user fica com versão antiga":

| Arquivo | Cache | Como invalida |
|---|---|---|
| `index.html` | **Nunca cacheia** (`no-cache, no-store, must-revalidate`) via `vercel.json` | Toda visita baixa fresh |
| `index.js`, `index.wasm`, imagens | Cache default do Vercel (revalida via ETag) | Novo deploy invalida CDN, browser revalida na próxima request |
| `index.pck` (Cloudflare R2) | Cache normal do browser | URL versionada `?v=<etag>` — cada pck novo vira URL diferente |

### `vercel.json`

Arquivo na raiz do repo que força HTML sempre fresh:

```json
{
  "headers": [
    {
      "source": "/index.html",
      "headers": [{ "key": "Cache-Control", "value": "no-cache, no-store, must-revalidate" }]
    },
    {
      "source": "/",
      "headers": [{ "key": "Cache-Control", "value": "no-cache, no-store, must-revalidate" }]
    }
  ]
}
```

### Por que isso basta

```
User abre o site
  ↓
Vercel entrega index.html FRESH (never cached)
  ↓
index.html referencia index.pck?v=<etag-novo>
  ↓
Browser: "URL nova" → baixa do R2
  ↓
User joga versão mais recente sem precisar Ctrl+Shift+R
```

HTML nunca cacheia + ETag do PCK muda a cada update = cadeia toda revalida
automaticamente. Zero intervenção do user.

### O que NÃO precisa fazer

- ❌ Hash nos nomes dos arquivos JS/WASM (Godot sobrescreve no export; complexidade desnecessária)
- ❌ Service worker customizado (overkill)
- ❌ Purge manual do CDN Vercel (Vercel faz automático ao deploy)
- ❌ Purge manual do Cloudflare R2 (ETag-based versioning no index.html já resolve)

Como `index.pck` está no `.gitignore` e `.vercelignore`, nem o GitHub nem o Vercel tentam subir o arquivo grande.

## Métodos de upload do pck pro R2

### Opção A — Wrangler CLI (recomendado, sem limite de tamanho)

Instale uma vez:
```bash
npm install -g wrangler
wrangler login
```

A cada build:
```bash
wrangler r2 object put lumera-assets/index.pck --file=./index.pck --remote
```

### Opção B — Dashboard (limite 300MB)

1. No R2 dashboard, abre o bucket `lumera-assets`
2. Deleta o `index.pck` antigo
3. Upload do novo via **Upload** → **Select from computer**

⚠️ UI só aceita até 300MB por arquivo. Pra arquivos maiores, use wrangler.

## Recuperar o `index.pck` localmente

Se precisar do arquivo no disco (para reexportar, testar local, etc.):

```bash
curl -L -o index.pck https://pub-932401cb337444cf95fc203c447835ce.r2.dev/index.pck
```

Ou via wrangler:
```bash
wrangler r2 object get lumera-assets/index.pck --file=./index.pck
```

Fica ignorado pelo git via `.gitignore`.

## Testar localmente antes do deploy

`file://` não funciona para Godot web (precisa de HTTP com CORS):

```bash
python -m http.server 8000
```

Acesse `http://localhost:8000` — o browser busca o pck direto do R2. Como o CORS está com `AllowedOrigins: ["*"]`, funciona de qualquer origem, inclusive `localhost`.

## Limites e custos Cloudflare R2

| Recurso | Free tier | Além disso |
|---|---|---|
| Storage | 10GB/mês | $0.015/GB/mês |
| Reads (Class B) | 10M/mês | $0.36 por milhão |
| Writes (Class A) | 1M/mês | $4.50 por milhão |
| Egress | **Ilimitado** (gratuito sempre) | — |

Para o Lumera em alpha/beta: **$0/mês** garantido até ~10M jogadores/mês.

## Otimização futura (reduzir tamanho do pck)

Estratégias no Godot para reduzir o `.pck`:

- **Áudio:** converter para OGG Vorbis (reduz 10x+ vs WAV).
- **Texturas:** ativar **VRAM Compressed** no painel Import (menor storage e melhor GPU).
- **Texturas 2D:** ativar **Lossy** onde qualidade total não importa.
- **Export Preset:** marcar apenas cenas/recursos necessários, desativar **Export with Debug** em produção.
- **Orphan Resources:** `Project → Project Settings → Tools → Orphan Resource Explorer` lista arquivos nunca referenciados.

## Troubleshooting

### "Failed to fetch" ao carregar o jogo
- Verifique se CORS está configurado no bucket R2 (Settings → CORS Policy).
- Teste no terminal:
  ```bash
  curl -sI -H "Origin: https://seu-dominio.vercel.app" https://pub-932401cb337444cf95fc203c447835ce.r2.dev/index.pck
  ```
  Deve conter `Access-Control-Allow-Origin: *`.

### Barra de progresso esquisita durante loading
- `fileSizes.index.pck` no `index.html` não bate com o tamanho real do arquivo.
- Atualize com `du -b index.pck`.

### Vercel rejeitando deploy com "File size limit exceeded"
- Algum arquivo grande entrou no diretório. Verifique se `index.pck` está no `.gitignore` e se não existe no working tree no momento do deploy.
