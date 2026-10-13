unit uDownloader;

{ Serviço de gerenciamento de downloads baseado no yt-dlp.

  Responsabilidades:
  - Fila de tarefas thread-safe (nova URL pode ser adicionada a qualquer momento).
  - Uma thread (TDownloadWorker) executa cada download independentemente.
  - Execução de processos externos (yt-dlp/ffmpeg) sem travar a interface e
    sem deadlock, via uProcessRunner.
  - Leitura do progresso real do yt-dlp (parâmetros --newline --progress e
    --progress-template) publicada como eventos consumidos pela thread principal.
  - Cancelamento por tarefa (encerra o processo externo e sinaliza a thread).

  As configurações do yt-dlp (formato, MP3 CBR 320 kbps para música avulsa e
  pipeline H.264 720p Baseline + AAC para vídeo) são preservadas.

  Os caminhos (yt-dlp/ffmpeg e pasta de destino) são resolvidos em tempo de
  execução a partir da pasta do próprio executável, para funcionar em qualquer
  máquina sem depender de caminhos absolutos do desenvolvedor. }

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.IOUtils,
  System.RegularExpressions,
  System.SyncObjs,
  uConfig,
  uProcessRunner;

const
  { Template de progresso do yt-dlp (uma linha por atualização, fácil de
    interpretar). Campos: baixado;total;velocidade(byte/s);eta(segundos);%. }
  YTDLP_PROGRESS_TEMPLATE =
    'download:[dlprog]%(progress.downloaded_bytes)s;' +
    '%(progress.total_bytes)s;%(progress.speed)s;' +
    '%(progress.eta)s;%(progress._percent_str)s';

type
  TDownloadKind = (dkMp3, dkMp4);

  TDownloadStatus = (dsQueued, dsRunning, dsDone, dsCanceled, dsError);

  TDownloadProgress = record
    Status: TDownloadStatus;
    Percent: Integer;    // -1 = indeterminado (ex.: obtendo título, convertendo)
    Downloaded: Int64;
    Total: Int64;
    Bps: Int64;          // velocidade atual (bytes/s)
    Eta: Int64;          // segundos restantes; -1 = desconhecido
    Phase: string;       // 'Baixando', 'Convertendo vídeo…', etc.
  end;

  TDownloadTask = record
    Id: Integer;
    Url: string;
    Kind: TDownloadKind;
    VideoHeight: Integer;  // resolução alvo (720/1080) — só dkMp4
    Codec: TVideoCodec;    // codec de saída do vídeo — só dkMp4
    Title: string;       // título obtido do yt-dlp
    Name: string;        // nome final do arquivo (sem extensão)
    FileName: string;    // caminho final quando concluído
    Error: string;
    Status: TDownloadStatus;
    Progress: TDownloadProgress;
    CancelRequested: Boolean;
  end;

  TDownloadEventKind = (devProgress, devDone, devFailed, devCanceled);

  TDownloadEvent = record
    Kind: TDownloadEventKind;
    Task: TDownloadTask;
  end;

  TExecuteResult = (erOk, erFailed, erCancelled);

  TDownloadManager = class
  private
    FLock: TMultiReadExclusiveWriteSynchronizer;
    FQueue: TList<TDownloadTask>;
    FActive: TDictionary<Integer, TDownloadTask>;
    FState: TDictionary<string, Integer>;           // URL normalizada -> Id
    FRunners: TDictionary<Integer, TProcessRunner>; // Id -> processo ativo
    FCancelled: TDictionary<Integer, Boolean>;
    FEvents: TList<TDownloadEvent>;
    FNextId: Integer;
    FStopping: Boolean;
    FDoneCount: Integer;
    FFailCount: Integer;
    FCancelCount: Integer;

    procedure StartWorker(const ATask: TDownloadTask);
    procedure Publish(const AKind: TDownloadEventKind; const ATask: TDownloadTask);
    function IsCancelled(const ATaskId: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { Constrói uma URL canônica do YouTube quando a entrada for um vídeo
      (watch?v=, youtu.be, /shorts/, /embed/). Retorna a própria URL quando
      não for possível identificar. AVideoId sai vazio quando não for vídeo. }
    class function NormalizeUrl(const AUrl: string; out AVideoId: string): string; static;

    { Remove numeração, sufixos de álbum, "(Official Video)" etc. e caracteres
      inválidos para nomes de arquivos no Windows. }
    class function CleanFileName(const ATitle: string): string; static;

    { Parâmetros de linha de comando do yt-dlp (configurações preservadas). }
    class function AudioParams(const ARemoteUrl, ASourceTemplate: string): string; static;
    class function VideoParams(const ARemoteUrl, ASourceTemplate: string;
      AHeight: Integer): string; static;
    class function FfmpegParams(const ASourceFile, AEncodedFile: string;
      AHeight: Integer; ACodec: TVideoCodec): string; static;
    class function TitleParams(const ARemoteUrl, AOutFile: string): string; static;
    class function SimulateVideoParams(const ARemoteUrl: string;
      AHeight: Integer): string; static;

    { Obtém o título real do vídeo consultando o yt-dlp (lê o arquivo gerado
      com --print-to-file). Retorna vazio em caso de falha ou cancelamento. }
    function ResolveTitle(const ATaskId: Integer; const ARemoteUrl,
      ATempId: string): string;

    { Verifica se a URL oferece vídeo até a altura pedida (consulta via
      --simulate). Sem vídeo disponível o download é abortado. }
    function HasVideo(const ATaskId: Integer; const ARemoteUrl: string;
      AHeight: Integer): Boolean;

    { Move um arquivo para o destino final, sobrescrevendo se necessário. }
    class function MoveFileOverwrite(const ASource, ADest: string): Boolean; static;

    { Adiciona uma tarefa à fila. ATask sai preenchido (Id atribuído). }
    function Enqueue(const AUrl: string; AKind: TDownloadKind;
      out ATask: TDownloadTask; out ADuplicate: Boolean): Boolean;

    { Engatilha as threads das tarefas pendentes. Retorna quantas foram iniciadas. }
    function Pump: Integer;

    { Consome os eventos publicados pelas threads. Deve ser chamado na thread
      principal. }
    function DrainEvents(out AEvents: TArray<TDownloadEvent>): Integer;

    function PendingCount: Integer;
    function ActiveCount: Integer;
    function DoneCount: Integer;
    function FailedCount: Integer;
    function CancelledCount: Integer;

    { Executa um processo externo registrado para a tarefa, permitindo
      cancelamento. AOnLine (opcional) recebe cada linha de saída. }
    function Execute(const ATaskId: Integer; const AExe, AParams, AWorkDir: string;
      const AOnLine: TProcessOutputEvent; out AExitCode: Cardinal): TExecuteResult;

    { Cancela uma tarefa. O processo associado é encerrado. }
    procedure Cancel(const ATaskId: Integer);

    { Cancela todas as tarefas em andamento. }
    procedure CancelAll;

    procedure Halt;
    procedure StopAll;

    function NewTempId(const ATaskId: Integer): string;
    procedure CleanTempFiles(const APrefix: string);
  end;

var
  { Caminhos resolvidos em tempo de execução (ver seção "initialization" no
    fim desta unit):
    - YTDLP_DIR: pasta onde ficam yt-dlp.exe e ffmpeg.exe. É procurada a partir
      da pasta do executável (mesma pasta, ..\ ou .\bin\), então NÃO existe
      caminho absoluto fixo de máquina.
    - DEST_DIR: pasta de destino dos downloads. Vem do INI (ClipDownloader.ini),
      que por padrão usa <usuário>\Downloads\Clips. }
  YTDLP_DIR: string;
  YTDLP_EXE: string;
  FFMPEG_EXE: string;
  DEST_DIR: string;
  TEMP_DIR: string;

{ Atualiza a pasta de destino (DEST_DIR/TEMP_DIR) em tempo de execução e garante
  que existam. Usado quando o usuário troca a pasta pelo botão "Destino...". }
procedure SetDestination(const APath: string);

implementation

uses
  System.NetEncoding;

type
  TDownloadWorker = class(TThread)
  private
    FManager: TDownloadManager;
    FTask: TDownloadTask;
    FIsFinished: Boolean;

    procedure PublishSnapshot;
    function Canceled: Boolean;
    procedure HandleProcessLine(Sender: TObject; const ALine: string);
    function DownloadAudio(const ATempId: string; out AFinalFile: string): TExecuteResult;
    function DownloadVideoClip(const ATempId: string; out AFinalFile: string): TExecuteResult;
    procedure PublishCanceled;
    function FailWith(const AMessage: string): TExecuteResult;
  public
    constructor Create(AManager: TDownloadManager; const ATask: TDownloadTask);
    procedure ProcessTask;
  protected
    procedure Execute; override;
  end;

{ ---------- Utilities ---------- }

{ Extensão do arquivo final por codec: VP9 sai em WebM; os demais em MP4. }
function CodecExt(ACodec: TVideoCodec): string;
begin
  if ACodec = vcVp9 then
    Result := '.webm'
  else
    Result := '.mp4';
end;

{ Localiza o arquivo baixado (fonte) pelo prefixo, independentemente da
  extensão/container que o yt-dlp escolher ao mesclar. }
function FindSourceFile(const APrefix: string): string;
var
  Files: TArray<string>;
  F: string;
begin
  Result := '';
  try
    Files := TDirectory.GetFiles(TEMP_DIR, APrefix + '.*');
  except
    Exit;
  end;
  for F in Files do
    if not SameText(ExtractFileExt(F), '.part') and
      not SameText(ExtractFileExt(F), '.ytdl') then
    begin
      Result := F;
      Exit;
    end;
end;

function NormalizeNumber(const S: string): string;
begin
  Result := Trim(S);
  Result := StringReplace(Result, ',', '.', [rfReplaceAll]);
end;

{ Interpreta tamanhos como "3.50MiB", "770KiB", "123B" e retorna bytes. }
function ParseSizeText(const S: string; out ABytes: Int64): Boolean;
var
  T: string;
  I: Integer;
  Num: string;
  Suffix: string;
  Mult: Int64;
  V: Double;
begin
  Result := False;
  ABytes := 0;
  T := Trim(S);
  if T = '' then
    Exit;
  I := 1;
  while (I <= Length(T)) and
    ((T[I] in ['0'..'9']) or (T[I] = '.') or (T[I] = ',')) do
    Inc(I);
  Num := Copy(T, 1, I - 1);
  Suffix := Trim(Copy(T, I, MaxInt));
  if Num = '' then
    Exit;
  V := StrToFloatDef(NormalizeNumber(Num), -1);
  if V < 0 then
    Exit;

  Suffix := UpperCase(StringReplace(Suffix, ' ', '', [rfReplaceAll]));
  Mult := 1;
  if Pos('TIB', Suffix) = 1 then
    Mult := Int64(1) shl 40
  else if Pos('GIB', Suffix) = 1 then
    Mult := Int64(1) shl 30
  else if Pos('MIB', Suffix) = 1 then
    Mult := Int64(1) shl 20
  else if Pos('KIB', Suffix) = 1 then
    Mult := Int64(1) shl 10
  else if Pos('TB', Suffix) = 1 then
    Mult := Int64(1000) * 1000 * 1000 * 1000
  else if Pos('GB', Suffix) = 1 then
    Mult := Int64(1000) * 1000 * 1000
  else if Pos('MB', Suffix) = 1 then
    Mult := Int64(1000) * 1000
  else if Pos('KB', Suffix) = 1 then
    Mult := 1000
  else if Pos('B', Suffix) = 1 then
    Mult := 1
  else
    Exit;

  ABytes := Round(V * Mult);
  Result := True;
end;

{ Interpreta ETA textual ("00:05", "01:23:45") em segundos. }
function ParseEtaText(const S: string; out AEta: Int64): Boolean;
var
  Parts: TArray<string>;
  Total: Integer;
  I: Integer;
begin
  Result := False;
  AEta := -1;
  Parts := Trim(S).Split([':']);
  if Length(Parts) < 2 then
    Exit;
  Total := 0;
  for I := 0 to High(Parts) do
    Total := (Total * 60) + StrToIntDef(Trim(Parts[I]), 0);
  AEta := Total;
  Result := True;
end;

{ Interpreta uma linha de progresso do yt-dlp (template [dlprog] ou o formato
  padrão "[download] X% of SIZE at SPEED ETA"). Atualiza P apenas. Retorna
  True quando a linha contém progresso. }
function ParseYtDlpProgress(const ALine: string; var P: TDownloadProgress): Boolean;
const
  TemplTag = '[dlprog]';
  TemplPat = '\[dlprog\]([-0-9]+);([-0-9]+);([.0-9]+|None);([-0-9]+|None);\s*([0-9,.]*)\s*%';
  StdPat = '\[download\]\s+([0-9]+(?:[.,][0-9]+)?)%\s+of\s+([0-9.,]+\s*[KMG]?i?B)(?:\s+at\s+([0-9.,]+\s*[KMG]?i?B/s))?(?:\s+ETA\s+(\S+))?';
  NoSizePat = '\[download\]\s+([0-9.,]+\s*[KMG]?i?B)\s+at\s+([0-9.,]+\s*[KMG]?i?B/s)';
var
  M: TMatch;
  V: Double;
  B: Int64;
  Eta: Int64;
begin
  Result := False;

  if Pos(TemplTag, ALine) = 1 then
  begin
    M := TRegEx.Match(ALine, TemplPat);
    if M.Success then
    begin
      P.Downloaded := StrToInt64Def(M.Groups[1].Value, 0);
      P.Total := StrToInt64Def(M.Groups[2].Value, 0);
      if (M.Groups[3].Value <> '') and (M.Groups[3].Value <> 'None') then
        P.Bps := Round(StrToFloatDef(NormalizeNumber(M.Groups[3].Value), 0))
      else
        P.Bps := 0;
      if (M.Groups[4].Value <> '') and (M.Groups[4].Value <> 'None') then
        P.Eta := StrToInt64Def(M.Groups[4].Value, -1)
      else
        P.Eta := -1;
      V := StrToFloatDef(M.Groups[5].Value, -1);
      if V >= 0 then
        P.Percent := Round(V);
      Result := True;
      Exit;
    end;
  end;

  M := TRegEx.Match(ALine, StdPat);
  if M.Success then
  begin
    V := StrToFloatDef(NormalizeNumber(M.Groups[1].Value), -1);
    if V >= 0 then
      P.Percent := Round(V);
    if ParseSizeText(M.Groups[2].Value, B) then
      P.Total := B;
    if (M.Groups[3].Value <> '') and ParseSizeText(M.Groups[3].Value, B) then
      P.Bps := B;
    if (M.Groups[4].Value <> '') and ParseEtaText(M.Groups[4].Value, Eta) then
      P.Eta := Eta;
    Result := True;
    Exit;
  end;

  { Progresso sem tamanho total: "[download]  31.3KiB at ..." }
  if Pos('[download]', ALine) > 0 then
  begin
    M := TRegEx.Match(ALine, NoSizePat);
    if M.Success then
    begin
      if ParseSizeText(M.Groups[1].Value, B) then
        P.Downloaded := B;
      if ParseSizeText(M.Groups[2].Value, B) then
        P.Bps := B;
      Result := True;
      Exit;
    end;
  end;

  { Linha "[download] 100% of ..." sem mais parâmetros. }
  if Pos('[download] 100%', ALine) > 0 then
  begin
    P.Percent := 100;
    Result := True;
  end;
end;

{ ---------- TDownloadWorker ---------- }

constructor TDownloadWorker.Create(AManager: TDownloadManager;
  const ATask: TDownloadTask);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FManager := AManager;
  FTask := ATask;
end;

function TDownloadWorker.Canceled: Boolean;
begin
  Result := FManager.IsCancelled(FTask.Id);
end;

procedure TDownloadWorker.PublishSnapshot;
begin
  FManager.Publish(devProgress, FTask);
end;

procedure TDownloadWorker.PublishCanceled;
begin
  FIsFinished := True;
  FTask.Status := dsCanceled;
  FTask.Progress.Status := dsCanceled;
  FTask.Progress.Phase := '';
  FTask.Error := '';
  FManager.Publish(devCanceled, FTask);
end;

function TDownloadWorker.FailWith(const AMessage: string): TExecuteResult;
begin
  FIsFinished := True;
  FTask.Status := dsError;
  FTask.Progress.Status := dsError;
  FTask.Progress.Phase := '';
  FTask.Error := AMessage;
  FManager.Publish(devFailed, FTask);
  Result := erFailed;
end;

procedure TDownloadWorker.HandleProcessLine(Sender: TObject; const ALine: string);
var
  Parsed: Boolean;
begin
  if FTask.Status <> dsRunning then
    Exit;

  if Pos('[ExtractAudio]', ALine) > 0 then
    FTask.Progress.Phase := 'Convertendo áudio…'
  else if (Pos('[Merger]', ALine) > 0) or
    (Pos('[VideoConvertor]', ALine) > 0) or
    (Pos('[EmbedThumbnail]', ALine) > 0) then
    FTask.Progress.Phase := 'Processando…';

  Parsed := ParseYtDlpProgress(ALine, FTask.Progress);
  if Parsed then
    PublishSnapshot;
end;

function TDownloadWorker.DownloadAudio(const ATempId: string;
  out AFinalFile: string): TExecuteResult;
var
  FinalPath, SourceTemplate, SourceFile: string;
  ExitCode: Cardinal;
  Res: TExecuteResult;
begin
  AFinalFile := '';
  FinalPath := TPath.Combine(DEST_DIR, FTask.Name + '.mp3');
  if FileExists(FinalPath) then
  begin
    AFinalFile := FinalPath;
    Exit(erOk);
  end;

  SourceTemplate := TPath.Combine(TEMP_DIR, FTask.Name + '_' + ATempId) + '.%(ext)s';

  Res := FManager.Execute(FTask.Id, YTDLP_EXE,
    TDownloadManager.AudioParams(FTask.Url, SourceTemplate), YTDLP_DIR,
    HandleProcessLine, ExitCode);
  if Res <> erOk then
    Exit(Res);

  SourceFile := ChangeFileExt(SourceTemplate, '.mp3');
  if not FileExists(SourceFile) then
    Exit(erFailed);

  if not TDownloadManager.MoveFileOverwrite(SourceFile, FinalPath) then
    Exit(erFailed);

  AFinalFile := FinalPath;
  Result := erOk;
end;

function TDownloadWorker.DownloadVideoClip(const ATempId: string;
  out AFinalFile: string): TExecuteResult;
var
  FinalPath, SourceTemplate, EncodedFile, SourceFile, Ext: string;
  ExitCode: Cardinal;
  Res: TExecuteResult;
begin
  AFinalFile := '';
  Ext := CodecExt(FTask.Codec);
  FinalPath := TPath.Combine(DEST_DIR, FTask.Name + Ext);
  if FileExists(FinalPath) then
  begin
    AFinalFile := FinalPath;
    Exit(erOk);
  end;

  SourceTemplate := TPath.Combine(TEMP_DIR, FTask.Name + '_' + ATempId +
    '_source') + '.%(ext)s';
  EncodedFile := TPath.Combine(TEMP_DIR, FTask.Name + '_' + ATempId +
    '_encoded' + Ext);

  Res := FManager.Execute(FTask.Id, YTDLP_EXE,
    TDownloadManager.VideoParams(FTask.Url, SourceTemplate, FTask.VideoHeight),
    YTDLP_DIR, HandleProcessLine, ExitCode);
  if Res <> erOk then
    Exit(Res);

  SourceFile := FindSourceFile(TPath.Combine(TEMP_DIR,
    FTask.Name + '_' + ATempId + '_source'));
  if SourceFile = '' then
    Exit(erFailed);

  { Re-encode final na resolução e codec escolhidos (H.264: Baseline 720p,
    AAC-LC 128 kbps — configuração original preservada). }
  FTask.Progress.Phase := 'Convertendo vídeo…';
  FTask.Progress.Percent := 100;
  PublishSnapshot;

  Res := FManager.Execute(FTask.Id, FFMPEG_EXE,
    TDownloadManager.FfmpegParams(SourceFile, EncodedFile, FTask.VideoHeight,
    FTask.Codec), YTDLP_DIR, nil, ExitCode);
  if Res <> erOk then
  begin
    DeleteFile(SourceFile);
    Exit(Res);
  end;

  if not FileExists(EncodedFile) then
  begin
    DeleteFile(SourceFile);
    Exit(erFailed);
  end;

  if FileExists(FinalPath) then
    DeleteFile(EncodedFile)
  else if not TDownloadManager.MoveFileOverwrite(EncodedFile, FinalPath) then
  begin
    DeleteFile(SourceFile);
    Exit(erFailed);
  end;

  DeleteFile(SourceFile);
  AFinalFile := FinalPath;
  Result := erOk;
end;

procedure TDownloadWorker.Execute;
begin
  try
    ProcessTask;
  except
    on E: Exception do
      if not FIsFinished then
        FailWith(E.Message);
  end;
end;

procedure TDownloadWorker.ProcessTask;
var
  TempId: string;
  Title: string;
  FinalFile: string;
  Res: TExecuteResult;
begin
  TempId := FManager.NewTempId(FTask.Id);

  FTask.Status := dsRunning;
  FTask.Progress.Status := dsRunning;
  FTask.Progress.Percent := -1;
  FTask.Progress.Phase := 'Iniciando…';
  PublishSnapshot;

  if Canceled then
  begin
    PublishCanceled;
    Exit;
  end;

  FTask.Progress.Phase := 'Obtendo título…';
  PublishSnapshot;
  Title := FManager.ResolveTitle(FTask.Id, FTask.Url, TempId);
  if Canceled then
  begin
    PublishCanceled;
    Exit;
  end;
  if Title = '' then
  begin
    FailWith('Não foi possível obter o título do vídeo.');
    Exit;
  end;

  FTask.Title := Title;
  FTask.Name := TDownloadManager.CleanFileName(Title);
  if FTask.Name = '' then
  begin
    FailWith('Não foi possível obter um nome de arquivo válido.');
    Exit;
  end;

  if FTask.Kind = dkMp4 then
  begin
    FTask.Progress.Phase := 'Verificando vídeo…';
    FTask.Progress.Percent := -1;
    PublishSnapshot;
    if Canceled then
    begin
      PublishCanceled;
      Exit;
    end;
    if not FManager.HasVideo(FTask.Id, FTask.Url, FTask.VideoHeight) then
    begin
      FailWith('Nenhum vídeo até ' + HeightName(FTask.VideoHeight) + ' disponível.');
      Exit;
    end;
    if Canceled then
    begin
      PublishCanceled;
      Exit;
    end;

    Res := DownloadVideoClip(TempId, FinalFile);
  end
  else
    Res := DownloadAudio(TempId, FinalFile);

  if Canceled then
  begin
    FManager.CleanTempFiles(FTask.Name + '_' + TempId);
    PublishCanceled;
    Exit;
  end;

  if Res <> erOk then
  begin
    FailWith('Falha no download ou na conversão.');
    Exit;
  end;
  if FinalFile = '' then
  begin
    FailWith('Arquivo final não encontrado.');
    Exit;
  end;

  FTask.Status := dsDone;
  FTask.FileName := FinalFile;
  FTask.Error := '';
  FTask.Progress.Status := dsDone;
  FTask.Progress.Phase := '';
  FTask.Progress.Percent := 100;
  FIsFinished := True;
  FManager.Publish(devDone, FTask);
end;

{ ---------- TDownloadManager ---------- }

constructor TDownloadManager.Create;
begin
  inherited Create;
  FLock := TMultiReadExclusiveWriteSynchronizer.Create;
  FQueue := TList<TDownloadTask>.Create;
  FActive := TDictionary<Integer, TDownloadTask>.Create;
  FState := TDictionary<string, Integer>.Create;
  FRunners := TDictionary<Integer, TProcessRunner>.Create;
  FCancelled := TDictionary<Integer, Boolean>.Create;
  FEvents := TList<TDownloadEvent>.Create;
  ForceDirectories(DEST_DIR);
  ForceDirectories(TEMP_DIR);
end;

destructor TDownloadManager.Destroy;
begin
  FStopping := True;
  StopAll;
  FreeAndNil(FRunners);
  FreeAndNil(FEvents);
  FreeAndNil(FCancelled);
  FreeAndNil(FActive);
  FreeAndNil(FState);
  FreeAndNil(FQueue);
  FreeAndNil(FLock);
  inherited Destroy;
end;

class function TDownloadManager.NormalizeUrl(const AUrl: string;
  out AVideoId: string): string;
const
  IdPat = '(?:youtube\.com/(?:watch\?v=|shorts/|embed/|v/)|youtu\.be/)([A-Za-z0-9_-]{6,})';
var
  S: string;
  M: TMatch;
begin
  S := Trim(AUrl);
  AVideoId := '';
  if S = '' then
    Exit('');

  M := TRegEx.Match(S, IdPat);
  if M.Success then
  begin
    AVideoId := M.Groups[1].Value;
    Result := 'https://www.youtube.com/watch?v=' + AVideoId;
  end
  else
    Result := S;
end;

class function TDownloadManager.CleanFileName(const ATitle: string): string;
var
  S: string;
begin
  S := Trim(ATitle);

  while (S <> '') and CharInSet(S[1], ['0'..'9']) do
    Delete(S, 1, 1);

  while (S <> '') and CharInSet(S[1], [' ', '-', '.', '_']) do
    Delete(S, 1, 1);

  S := StringReplace(S, ' | A COLORS SHOW', '', [rfIgnoreCase, rfReplaceAll]);
  S := StringReplace(S, ' (Official Music Video)', '', [rfIgnoreCase, rfReplaceAll]);
  S := StringReplace(S, ' (Official Video)', '', [rfIgnoreCase, rfReplaceAll]);
  S := StringReplace(S, ' (Official Audio)', '', [rfIgnoreCase, rfReplaceAll]);
  S := StringReplace(S, ' (Explicit)', '', [rfIgnoreCase, rfReplaceAll]);
  S := StringReplace(S, ' (Clean)', '', [rfIgnoreCase, rfReplaceAll]);

  S := StringReplace(S, '｜', ' ', [rfReplaceAll]);   // barra vertical full-width
  S := StringReplace(S, '|', ' ', [rfReplaceAll]);
  S := StringReplace(S, '¦', ' ', [rfReplaceAll]);

  S := StringReplace(S, '\', ' ', [rfReplaceAll]);
  S := StringReplace(S, '/', ' ', [rfReplaceAll]);
  S := StringReplace(S, ':', ' ', [rfReplaceAll]);
  S := StringReplace(S, '*', ' ', [rfReplaceAll]);
  S := StringReplace(S, '?', ' ', [rfReplaceAll]);
  S := StringReplace(S, '"', ' ', [rfReplaceAll]);
  S := StringReplace(S, '<', ' ', [rfReplaceAll]);
  S := StringReplace(S, '>', ' ', [rfReplaceAll]);

  while Pos('  ', S) > 0 do
    S := StringReplace(S, '  ', ' ', [rfReplaceAll]);

  Result := Trim(S);
end;

class function TDownloadManager.AudioParams(const ARemoteUrl,
  ASourceTemplate: string): string;
begin
  Result :=
    '--extract-audio --audio-format mp3 --audio-quality 320K ' +
    '--newline --progress --progress-template "' + YTDLP_PROGRESS_TEMPLATE + '" ' +
    '--no-warnings --no-overwrites -o "' + ASourceTemplate + '" "' + ARemoteUrl + '"';
end;

class function TDownloadManager.VideoParams(const ARemoteUrl,
  ASourceTemplate: string; AHeight: Integer): string;
var
  H: string;
begin
  H := IntToStr(AHeight);
  { A saída final é sempre re-encodada no codec/resolução escolhidos, então a
    origem apenas precisa ter o melhor vídeo até a altura pedida. }
  Result :=
    '--no-warnings ' +
    '-f "bv*[height<=' + H + ']+ba/bv*[height<=' + H + ']/b[height<=' + H + ']" ' +
    '--merge-output-format mkv ' +
    '--newline --progress --progress-template "' + YTDLP_PROGRESS_TEMPLATE + '" ' +
    '--no-overwrites -o "' + ASourceTemplate + '" "' + ARemoteUrl + '"';
end;

class function TDownloadManager.FfmpegParams(const ASourceFile,
  AEncodedFile: string; AHeight: Integer; ACodec: TVideoCodec): string;
var
  W, H, VEnc, AEnc, MovFlags: string;
begin
  if AHeight = 1080 then
  begin
    W := '1920';
    H := '1080';
  end
  else
  begin
    W := '1280';
    H := '720';
  end;

  case ACodec of
    vcH265: VEnc := '-c:v libx265 -preset medium -crf 24';
    vcVp9: VEnc := '-c:v libvpx-vp9 -crf 32 -b:v 0 -row-mt 1';
    vcAv1: VEnc := '-c:v libaom-av1 -crf 32 -b:v 0 -cpu-used 6';
    vcMpeg4: VEnc := '-c:v mpeg4 -q:v 5';
  else
    VEnc := '-c:v libx264 -profile:v baseline -level 3.1 -b:v 1M';
  end;

  if ACodec = vcVp9 then
  begin
    AEnc := '-c:a libopus -b:a 128k -ar 48000 -ac 2';
    MovFlags := '';
  end
  else
  begin
    AEnc := '-c:a aac -b:a 128k -ar 44100 -ac 2';
    MovFlags := '-movflags +faststart ';
  end;

  Result :=
    '-y -i "' + ASourceFile + '" ' +
    VEnc + ' ' +
    '-vf "scale=' + W + ':' + H + ':force_original_aspect_ratio=decrease,' +
    'pad=' + W + ':' + H + ':(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30" ' +
    AEnc + ' ' +
    MovFlags + '-strict experimental "' + AEncodedFile + '"';
end;

class function TDownloadManager.TitleParams(const ARemoteUrl,
  AOutFile: string): string;
begin
  Result :=
    '--print-to-file "%(title)s" "' + AOutFile +
    '" --skip-download --no-warnings "' + ARemoteUrl + '"';
end;

class function TDownloadManager.SimulateVideoParams(const ARemoteUrl: string;
  AHeight: Integer): string;
var
  H: string;
begin
  H := IntToStr(AHeight);
  Result :=
    '--simulate --skip-download --no-warnings ' +
    '-f "bv*[height<=' + H + ']/b[height<=' + H + ']" "' + ARemoteUrl + '"';
end;

class function TDownloadManager.MoveFileOverwrite(const ASource,
  ADest: string): Boolean;
begin
  Result := MoveFileEx(PChar(ASource), PChar(ADest),
    MOVEFILE_REPLACE_EXISTING or MOVEFILE_COPY_ALLOWED);
end;

function TDownloadManager.NewTempId(const ATaskId: Integer): string;
begin
  Result := IntToStr(ATaskId) + '_' + IntToStr(GetCurrentThreadId);
end;

function TDownloadManager.PendingCount: Integer;
begin
  FLock.BeginWrite;
  try
    Result := FQueue.Count;
  finally
    FLock.EndWrite;
  end;
end;

function TDownloadManager.ActiveCount: Integer;
begin
  FLock.BeginWrite;
  try
    Result := FActive.Count;
  finally
    FLock.EndWrite;
  end;
end;

function TDownloadManager.DoneCount: Integer;
begin
  FLock.BeginWrite;
  try
    Result := FDoneCount;
  finally
    FLock.EndWrite;
  end;
end;

function TDownloadManager.FailedCount: Integer;
begin
  FLock.BeginWrite;
  try
    Result := FFailCount;
  finally
    FLock.EndWrite;
  end;
end;

function TDownloadManager.CancelledCount: Integer;
begin
  FLock.BeginWrite;
  try
    Result := FCancelCount;
  finally
    FLock.EndWrite;
  end;
end;

function TDownloadManager.IsCancelled(const ATaskId: Integer): Boolean;
begin
  FLock.BeginWrite;
  try
    Result := FCancelled.ContainsKey(ATaskId);
  finally
    FLock.EndWrite;
  end;
end;

function TDownloadManager.Enqueue(const AUrl: string; AKind: TDownloadKind;
  out ATask: TDownloadTask; out ADuplicate: Boolean): Boolean;
var
  Norm: string;
  DummyVideoId: string;
  T: TDownloadTask;
begin
  Result := False;
  ADuplicate := False;
  ATask := Default(TDownloadTask);

  Norm := NormalizeUrl(AUrl, DummyVideoId);
  if Norm = '' then
    Exit;

  FLock.BeginWrite;
  try
    if FStopping then
      Exit;

    if FState.ContainsKey(Norm) then
    begin
      ADuplicate := True;
      Exit;
    end;

    Inc(FNextId);
    T.Id := FNextId;
    T.Url := Norm;
    T.Kind := AKind;
    T.VideoHeight := AppConfig.VideoHeight;
    T.Codec := AppConfig.Codec;
    T.Status := dsQueued;
    T.Progress.Status := dsQueued;
    T.Progress.Percent := 0;
    T.Progress.Downloaded := 0;
    T.Progress.Total := 0;
    T.Progress.Bps := 0;
    T.Progress.Eta := -1;

    FQueue.Add(T);
    FState.Add(Norm, T.Id);
    ATask := T;
    Result := True;
  finally
    FLock.EndWrite;
  end;
end;

function TDownloadManager.Pump: Integer;
var
  Task: TDownloadTask;
begin
  Result := 0;
  while True do
  begin
    FLock.BeginWrite;
    try
      if FStopping or (FQueue.Count = 0) then
        Exit;
      Task := FQueue[0];
      FQueue.Delete(0);
      FActive.Add(Task.Id, Task);
    finally
      FLock.EndWrite;
    end;

    StartWorker(Task);
    Inc(Result);
  end;
end;

procedure TDownloadManager.StartWorker(const ATask: TDownloadTask);
var
  W: TDownloadWorker;
begin
  W := TDownloadWorker.Create(Self, ATask);
  W.Start;
end;

function TDownloadManager.DrainEvents(out AEvents: TArray<TDownloadEvent>): Integer;
var
  I: Integer;
begin
  AEvents := nil;
  FLock.BeginWrite;
  try
    Result := FEvents.Count;
    if Result = 0 then
      Exit;
    SetLength(AEvents, Result);
    for I := 0 to Result - 1 do
    begin
      AEvents[I] := FEvents[0];
      FEvents.Delete(0);
    end;
  finally
    FLock.EndWrite;
  end;
end;

procedure TDownloadManager.Publish(const AKind: TDownloadEventKind;
  const ATask: TDownloadTask);
var
  Ev: TDownloadEvent;
begin
  FLock.BeginWrite;
  try
    { Anexa o evento antes de liberar a tarefa de FActive: assim, quando
      ActiveCount retornar a zero, a thread já terminou qualquer acesso a
      FEvents e pode liberar a tarefa com segurança. }
    Ev.Kind := AKind;
    Ev.Task := ATask;
    FEvents.Add(Ev);

    case AKind of
      devDone:
        begin
          Inc(FDoneCount);
          FActive.Remove(ATask.Id);
          FCancelled.Remove(ATask.Id);
        end;
      devFailed:
        begin
          Inc(FFailCount);
          FActive.Remove(ATask.Id);
          FState.Remove(ATask.Url);
          FCancelled.Remove(ATask.Id);
        end;
      devCanceled:
        begin
          Inc(FCancelCount);
          FActive.Remove(ATask.Id);
          FState.Remove(ATask.Url);
          FCancelled.Remove(ATask.Id);
        end;
      devProgress:
        ;
    end;
  finally
    FLock.EndWrite;
  end;
end;

function TDownloadManager.Execute(const ATaskId: Integer;
  const AExe, AParams, AWorkDir: string; const AOnLine: TProcessOutputEvent;
  out AExitCode: Cardinal): TExecuteResult;
var
  R: TProcessRunner;
begin
  Result := erFailed;
  AExitCode := Cardinal(-1);
  if FStopping then
    Exit;

  R := TProcessRunner.Create(AExe, AParams, AWorkDir);
  try
    if Assigned(AOnLine) then
      R.OnLine := AOnLine;

    FLock.BeginWrite;
    try
      FRunners.AddOrSetValue(ATaskId, R);
    finally
      FLock.EndWrite;
    end;

    R.Run;
    AExitCode := R.ExitCode;
  finally
    FLock.BeginWrite;
    try
      FRunners.Remove(ATaskId);
    finally
      FLock.EndWrite;
    end;
    R.Free;
  end;

  if IsCancelled(ATaskId) then
    Result := erCancelled
  else if AExitCode = 0 then
    Result := erOk
  else
    Result := erFailed;
end;

function TDownloadManager.ResolveTitle(const ATaskId: Integer;
  const ARemoteUrl, ATempId: string): string;
var
  OutFile: string;
  ExitCode: Cardinal;
  L: TStringList;
  Res: TExecuteResult;
begin
  Result := '';
  OutFile := TPath.Combine(TEMP_DIR, 'title_' + ATempId + '.txt');
  try
    DeleteFile(OutFile);
    Res := Execute(ATaskId, YTDLP_EXE, TitleParams(ARemoteUrl, OutFile),
      YTDLP_DIR, nil, ExitCode);
    if Res <> erOk then
      Exit;
    if not FileExists(OutFile) then
      Exit;

    L := TStringList.Create;
    try
      L.LoadFromFile(OutFile, TEncoding.UTF8);
      if L.Count > 0 then
        Result := Trim(L[0]);
    finally
      L.Free;
    end;
  finally
    if FileExists(OutFile) then
      DeleteFile(OutFile);
  end;
end;

function TDownloadManager.HasVideo(const ATaskId: Integer;
  const ARemoteUrl: string; AHeight: Integer): Boolean;
var
  ExitCode: Cardinal;
begin
  Result := Execute(ATaskId, YTDLP_EXE, SimulateVideoParams(ARemoteUrl, AHeight),
    YTDLP_DIR, nil, ExitCode) = erOk;
end;

procedure TDownloadManager.CleanTempFiles(const APrefix: string);
var
  Files: TArray<string>;
  F: string;
begin
  if APrefix = '' then
    Exit;
  try
    Files := TDirectory.GetFiles(TEMP_DIR, APrefix + '*');
  except
    Exit;
  end;
  for F in Files do
    TFile.Delete(F);
end;

procedure TDownloadManager.Cancel(const ATaskId: Integer);
var
  R: TProcessRunner;
begin
  FLock.BeginWrite;
  try
    FCancelled.AddOrSetValue(ATaskId, True);
    if FRunners.TryGetValue(ATaskId, R) and (R <> nil) then
      R.Cancel;
  finally
    FLock.EndWrite;
  end;
end;

procedure TDownloadManager.CancelAll;
var
  Keys: TArray<Integer>;
  I: Integer;
  R: TProcessRunner;
begin
  FLock.BeginWrite;
  try
    Keys := FRunners.Keys.ToArray;
    for I := Low(Keys) to High(Keys) do
    begin
      FCancelled.AddOrSetValue(Keys[I], True);
      if FRunners.TryGetValue(Keys[I], R) and (R <> nil) then
        R.Cancel;
    end;
  finally
    FLock.EndWrite;
  end;
end;

procedure TDownloadManager.Halt;
begin
  FLock.BeginWrite;
  try
    FStopping := True;
  finally
    FLock.EndWrite;
  end;
end;

procedure TDownloadManager.StopAll;
begin
  CancelAll;
end;

{ ---------- Resolução de caminhos (portável) ---------- }

{ Normaliza um diretório: caminho absoluto e sem barra final (a barra é
  preservada em raízes como "C:\"). }
function NormalizeDir(const ADir: string): string;
begin
  Result := TPath.GetFullPath(ADir);
  if (Length(Result) > 3) and (Result[Length(Result)] = PathDelim) then
    Result := Copy(Result, 1, Length(Result) - 1);
end;

function HasTool(const ADir, AFile: string): Boolean;
begin
  Result := FileExists(TPath.Combine(ADir, AFile));
end;

{ Procura a pasta com yt-dlp.exe/ffmpeg.exe a partir da pasta do executável,
  eliminando a dependência de caminhos absolutos do desenvolvedor.
  Ordem: pasta do exe -> pasta pai (..\) -> subpasta bin\ -> pasta pai. }
function ResolveToolsDir: string;
var
  Base, Parent, Bin: string;
begin
  Base := NormalizeDir(ExtractFilePath(ParamStr(0)));
  Parent := NormalizeDir(TPath.Combine(Base, '..'));
  Bin := NormalizeDir(TPath.Combine(Base, 'bin'));

  if HasTool(Base, 'yt-dlp.exe') then
    Exit(Base);
  if HasTool(Parent, 'yt-dlp.exe') then
    Exit(Parent);
  if HasTool(Bin, 'yt-dlp.exe') then
    Exit(Bin);
  Result := Parent;
end;

procedure SetDestination(const APath: string);
begin
  if Trim(APath) = '' then
    Exit;
  DEST_DIR := NormalizeDir(APath);
  TEMP_DIR := TPath.Combine(DEST_DIR, '_temp');
  ForceDirectories(DEST_DIR);
  ForceDirectories(TEMP_DIR);
end;

initialization
  YTDLP_DIR := ResolveToolsDir;
  YTDLP_EXE := TPath.Combine(YTDLP_DIR, 'yt-dlp.exe');
  FFMPEG_EXE := TPath.Combine(YTDLP_DIR, 'ffmpeg.exe');
  SetDestination(AppConfig.SavePath);

end.