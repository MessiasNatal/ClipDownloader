# Clip Downloader

Aplicativo desktop para Windows, feito em **Delphi (VCL)**, que integra um navegador (**Microsoft Edge WebView2**) e usa o [yt-dlp](https://github.com/yt-dlp/yt-dlp) + [ffmpeg](https://ffmpeg.org/) para baixar músicas e vídeos com um clique.

> Desenvolvido com o auxílio do **OPENCODE**.

## O que faz

- **Navegador embutido:** abre o YouTube (ou qualquer site) dentro do app, com barra de endereço, voltar/avançar/recarregar/início.
- **Escolha de formato:**
  - **MP3 (áudio 320 kbps)** para músicas.
  - **MP4 (vídeo 720p H.264)** com re-encode via ffmpeg.
- **Barra lateral de downloads** com progresso real (percentual, velocidade e ETA), status por item, cancelamento e botão **Abrir**.
- **Fila de downloads** com execução em threads, sem travar a interface e com cancelamento seguro.
- **Filtro de codec:** o download de vídeo só prossegue se houver H.264 até 720p disponível.
- **Organização automática de nomes** (remove numeração, `(Official Video)`, `|` full-width etc.).

## Especificações de saída

- **Áudio:** MP3 CBR 320 kbps.
- **Vídeo:** MP4, H.264 Baseline, 1280x720, 30 FPS, ~1 Mbps; áudio AAC-LC 128 kbps / 44.1 kHz.

## Requisitos

- **Delphi / RAD Studio** (VCL) para compilar o projeto.
- **Microsoft Edge WebView2 Runtime** instalado e o `WebView2Loader.dll` ao lado do executável.
- **`yt-dlp.exe`** e **`ffmpeg.exe`** disponíveis para o app usar.

## Estrutura do projeto

```
system/
  ClipDownloader.dpr        # projeto Delphi
  ClipDownloader.dproj
  src/
    uMain.pas               # interface (navegador + barra lateral de downloads)
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
- **Pasta de destino:** usa a variável de ambiente `CLIPDOWNLOADER_DEST` se definida; caso contrário, `<usuário>\Downloads\Clips`.

Para mudar a pasta de destino sem recompilar, defina antes de abrir o app:

```powershell
setx CLIPDOWNLOADER_DEST "D:\Music\Clips"
```

## Aviso

Projeto pessoal, sem fins de redistribuição. Respeite os direitos autorais e os termos de uso de cada plataforma.
