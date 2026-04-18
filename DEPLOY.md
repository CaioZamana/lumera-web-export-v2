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

## Histórico de tentativas

1. ❌ Deploy completo no Vercel — bloqueado pelo limite de 100MB/arquivo.
2. ❌ GitHub Releases — hospedagem funcionou mas não envia header `Access-Control-Allow-Origin`, bloqueado por CORS.
3. ✅ Cloudflare R2 — resolve ambos: sem limite de tamanho E com CORS configurável.

## Alterações no repositório

### `index.html`

Adicionada variável `GODOT_PCK_URL` e campo `mainPack` no `GODOT_CONFIG` para apontar o engine do Godot à URL externa do pck:

```js
const GODOT_PCK_URL = "https://pub-932401cb337444cf95fc203c447835ce.r2.dev/index.pck";
const GODOT_CONFIG = { ..., "mainPack": GODOT_PCK_URL };
```

O campo `fileSizes.index.pck` também foi atualizado para o tamanho real em bytes — usado pela barra de progresso de loading.

### `.gitignore`

Adicionado `index.pck` para garantir que o arquivo nunca seja commitado (GitHub rejeita >100MB em repos normais).

```
.vercel
.env*.local
index.pck
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

1. Garanta que o `index.pck` no R2 corresponde à versão atual do export.
2. Garanta que `GODOT_PCK_URL` e `fileSizes.index.pck` no `index.html` estão corretos.
3. Deploy no Vercel:
   ```bash
   vercel --prod
   ```

Como `index.pck` está no `.gitignore`, o Vercel nunca tenta subir o arquivo grande.

## Atualizar o jogo (nova versão do pck)

### Opção A — Wrangler CLI (recomendado, sem limite de tamanho)

Instale uma vez:
```bash
npm install -g wrangler
wrangler login
```

A cada nova build:
```bash
# 1. Export novo do Godot gera index.pck no diretório
# 2. Upload pro R2 (substitui o anterior):
wrangler r2 object put lumera-assets/index.pck --file=./index.pck --remote

# 3. Se o tamanho mudou, atualiza no index.html:
du -b index.pck
# copia o número e atualiza fileSizes.index.pck em index.html

# 4. Deploy:
git add index.html
git commit -m "update pck"
git push
vercel --prod
```

### Opção B — Dashboard (limite 300MB)

1. No R2 dashboard, abre o bucket `lumera-assets`
2. Deleta o `index.pck` antigo
3. Upload do novo via **Upload** → **Select from computer**
4. Atualiza `fileSizes.index.pck` no `index.html`
5. Commit + push + `vercel --prod`

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
