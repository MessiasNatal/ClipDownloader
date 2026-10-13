# Clip Downloader

Aplicativo desktop para Windows, feito em **Delphi (VCL)**, que integra um navegador (**Microsoft Edge WebView2**) e usa o [yt-dlp](https://github.com/yt-dlp/yt-dlp) + [ffmpeg](https://ffmpeg.org/) para baixar músicas e vídeos com um clique.

> Desenvolvido com o auxílio do **OPENCODE**.

## O que faz

- **Navegador embutido:** abre o YouTube (ou qualquer site) dentro do app, com barra de endereço, voltar/avançar/recarregar/início.
- **Escolha de formato:**
  - **MP3 (áudio 320 kbps)** para músicas.
  - **MP4 720p** (padrão) ou **MP4 1080p**, com re-encode via ffmpeg.
- **Escolha de codec de vídeo** (só para MP4): **H.264 (padrão)**, H.265 (HEVC), VP9 (WebM), AV1 e MPEG-4.
- **Escolha da pasta de destino** pelo botão **Destino…** (salva no INI).
- **Botão Restaurar:** volta os tipos aos padrões originais (MP4 720p + H.264).
- **Barra lateral de downloads** com progresso real (percentual, velocidade e ETA), status por item, cancelamento e botão **Abrir**.
- **Fila de downloads** com execução em threads, sem travar a interface e com cancelamento seguro.
- **Verificação de disponibilidade:** o download de vídeo só prossegue se houver vídeo até a altura escolhida.
- **Organização automática de nomes** (remove numeração, `(Official Video)`, `|` full-width etc.).

## Especificações de saída

- **Áudio:** MP3 CBR 320 kbps.
- **Vídeo (H.264, padrão):** MP4, H.264 Baseline, 1280x720 (ou 1920x1080), 30 FPS, ~1 Mbps; áudio AAC-LC 128 kbps / 44.1 kHz.
- **Vídeo (outros codecs):** H.265 → MP4 (libx265); AV1 → MP4 (libaom-av1); MPEG-4 → MP4; VP9 → **WebM** (libvpx-vp9 + Opus).

## Requisitos

- **Delphi / RAD Studio** (VCL) para compilar o projeto.
- **Microsoft Edge WebView2 Runtime** instalado e o `WebView2Loader.dll` ao lado do executável.
- **`yt-dlp.exe`** e **`ffmpeg.exe`** disponíveis para o app usar.

## Estrutura do projeto

```
system/
  ClipDownloader.dpr        # projeto Delphi
  ClipDownloader.dproj
  ClipDownloader.ini        # configurações (criado na 1ª execução)
  src/
    uMain.pas               # interface (navegador + barra lateral de downloads)
    uConfig.pas             # leitura/gravação do INI (destino, resolução, codec)
    uDownloader.pas         # gerenciador de downloads (fila + threads)
    uProcessRunner.pas      # execução de processos externos sem deadlock
  WebView2Loader.dll
```

## Como compilar e usar

1. Abra `system\ClipDownloader.dproj` no Delphi/RAD Studio e compile.
2. Garanta que `yt-dlp.exe` e `ffmpeg.exe` estejam **na pasta do executável, na pasta pai (`..\`) ou em `bin\`**.
3. Execute, abra um vídeo e clique em **Baixar**.

### Caminhos (portáveis)

O aplicativo não usa caminhos absolutos de máquina. Ao iniciar, ele resolve:

- **yt-dlp/ffmpeg:** procura `yt-dlp.exe` na pasta do executável, depois em `..\` e em `bin\`.
- **Pasta de destino:** lê do INI; na primeira execução usa `CLIPDOWNLOADER_DEST` (se definida) ou `<usuário>\Downloads\Clips`.

### Configuração (ClipDownloader.ini)

Criado ao lado do executável na primeira execução e atualizado quando você muda
as opções na interface:

```ini
[Download]
SavePath=D:\Music\Clips

[Video]
Resolution=720          ; 720 | 1080
Codec=h264              ; h264 | h265 | vp9 | av1 | mpeg4
```

- **Pasta de destino:** mude pelo botão **Destino…** (ou edite `SavePath` e reabra o app).
- **Resolução e codec:** mude pelos combos na barra de ferramentas; são gravados automaticamente.

## Aviso

Projeto pessoal, sem fins de redistribuição. Respeite os direitos autorais e os termos de uso de cada plataforma.
