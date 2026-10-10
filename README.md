# YDownload — Downloader de músicas e vídeos (yt-dlp + ffmpeg)

Ferramenta pessoal baseada no [yt-dlp](https://github.com/yt-dlp/yt-dlp) e no [ffmpeg](https://ffmpeg.org/) para baixar e organizar músicas e vídeos automaticamente, com regras fixas de qualidade, formato, nomeação de arquivos e pasta de destino.

## O que faz

- **Músicas (link único):** extrai áudio em **MP3 320 kbps**.
- **Álbuns/playlists:** baixa em **MP3 V0 (VBR, ~245 kbps)** e organiza em `Artista\Álbum`.
- **Vídeos:** baixa em **MP4 H.264 Baseline, 1280x720, 30 FPS** com áudio **AAC-LC 128 kbps / 44.1 kHz**, re-encodando com ffmpeg para garantir as especificações exatas (com padding para não distorcer vídeos 4:3).

## Padrões seguidos

- Nome do arquivo sempre `Artista - Música.ext`, sem numeração e sem lixo de título (`(Official Video)`, sufixos de álbum, barra vertical full-width `|` U+FF5C, etc.).
- Participações (`feat.` / `ft.`) são mantidas.
- Destino padrão configurável por pasta.

## Estrutura

- `yt-dlp.exe` — baixador.
- `ffmpeg.exe` — pós-processamento (conversão MP3 / re-encode MP4).
- `AGENTS.md` — as convenções e os comandos usados.

## Como usar

Basta rodar o `yt-dlp.exe` com as flags documentadas no `AGENTS.md`. Exemplo (música avulsa em MP3 320 kbps):

```powershell
.\yt-dlp.exe --extract-audio --audio-format mp3 --audio-quality 320K -o "M:\Clips\%(title)s.%(ext)s" "URL"
```

## Aviso

Projeto pessoal, sem fins de redistribuição. Respeite os direitos autorais e os termos de uso de cada plataforma.
