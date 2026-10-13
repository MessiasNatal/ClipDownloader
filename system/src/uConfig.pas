unit uConfig;

{ Configurações persistentes do aplicativo, gravadas em um arquivo INI ao lado
  do executável (ClipDownloader.ini):

    [Download]
    SavePath=<pasta de destino>

    [Video]
    Resolution=720|1080
    Codec=h264|h265|vp9|av1|mpeg4

  Os valores padrão (pasta padrão do usuário, 720p e H.264) são aplicados e
  gravados na primeira execução. }

interface

uses
  System.SysUtils,
  System.IOUtils;

type
  TVideoCodec = (vcH264, vcH265, vcVp9, vcAv1, vcMpeg4);

  TAppConfig = class
  private
    FIniPath: string;
    FSavePath: string;
    FVideoHeight: Integer;   // 720 ou 1080
    FCodec: TVideoCodec;
    function DefaultSavePath: string;
  public
    constructor Create;
    procedure Load;
    procedure Save;
    property IniPath: string read FIniPath;
    property SavePath: string read FSavePath write FSavePath;
    property VideoHeight: Integer read FVideoHeight write FVideoHeight;
    property Codec: TVideoCodec read FCodec write FCodec;
  end;

{ Identificadores gravados no INI e nomes exibidos na interface. }
function CodecId(ACodec: TVideoCodec): string;
function CodecFromId(const AId: string): TVideoCodec;
function CodecName(ACodec: TVideoCodec): string;
function CodecList: TArray<TVideoCodec>;
function HeightId(AHeight: Integer): string;
function HeightFromId(const AId: string): Integer;
function HeightName(AHeight: Integer): string;

var
  AppConfig: TAppConfig;

implementation

uses
  System.IniFiles;

const
  SectionDownload = 'Download';
  SectionVideo = 'Video';

function CodecId(ACodec: TVideoCodec): string;
begin
  case ACodec of
    vcH265: Result := 'h265';
    vcVp9: Result := 'vp9';
    vcAv1: Result := 'av1';
    vcMpeg4: Result := 'mpeg4';
  else
    Result := 'h264';
  end;
end;

function CodecFromId(const AId: string): TVideoCodec;
var
  S: string;
begin
  S := LowerCase(Trim(AId));
  if S = 'h265' then
    Result := vcH265
  else if S = 'vp9' then
    Result := vcVp9
  else if S = 'av1' then
    Result := vcAv1
  else if S = 'mpeg4' then
    Result := vcMpeg4
  else
    Result := vcH264;
end;

function CodecName(ACodec: TVideoCodec): string;
begin
  case ACodec of
    vcH265: Result := 'H.265 (HEVC)';
    vcVp9: Result := 'VP9 (WebM)';
    vcAv1: Result := 'AV1';
    vcMpeg4: Result := 'MPEG-4';
  else
    Result := 'H.264 (AVC)';
  end;
end;

function CodecList: TArray<TVideoCodec>;
begin
  Result := [vcH264, vcH265, vcVp9, vcAv1, vcMpeg4];
end;

function HeightId(AHeight: Integer): string;
begin
  if AHeight = 1080 then
    Result := '1080'
  else
    Result := '720';
end;

function HeightFromId(const AId: string): Integer;
begin
  if Trim(AId) = '1080' then
    Result := 1080
  else
    Result := 720;
end;

function HeightName(AHeight: Integer): string;
begin
  if AHeight = 1080 then
    Result := '1080p'
  else
    Result := '720p';
end;

{ TAppConfig }

constructor TAppConfig.Create;
begin
  inherited Create;
  FIniPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'ClipDownloader.ini');
  FSavePath := DefaultSavePath;
  FVideoHeight := 720;
  FCodec := vcH264;
  Load;
  Save;   // aplica/grava padrões na primeira execução
end;

function TAppConfig.DefaultSavePath: string;
var
  Env: string;
begin
  Env := Trim(GetEnvironmentVariable('CLIPDOWNLOADER_DEST'));
  if Env <> '' then
    Exit(TPath.GetFullPath(Env));

  Env := Trim(GetEnvironmentVariable('USERPROFILE'));
  if Env <> '' then
    Exit(TPath.Combine(TPath.Combine(Env, 'Downloads'), 'Clips'));

  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'downloads');
end;

procedure TAppConfig.Load;
var
  Ini: TIniFile;
begin
  if not FileExists(FIniPath) then
    Exit;
  try
    Ini := TIniFile.Create(IniPath);
    try
      FSavePath := Trim(Ini.ReadString(SectionDownload, 'SavePath', ''));
      if FSavePath = '' then
        FSavePath := DefaultSavePath;
      FVideoHeight := HeightFromId(Ini.ReadString(SectionVideo, 'Resolution', '720'));
      FCodec := CodecFromId(Ini.ReadString(SectionVideo, 'Codec', 'h264'));
    finally
      Ini.Free;
    end;
  except
    { INI inacessível/ inválido: mantém os padrões em memória. }
  end;
end;

procedure TAppConfig.Save;
var
  Ini: TIniFile;
begin
  try
    Ini := TIniFile.Create(IniPath);
    try
      Ini.WriteString(SectionDownload, 'SavePath', FSavePath);
      Ini.WriteString(SectionVideo, 'Resolution', HeightId(FVideoHeight));
      Ini.WriteString(SectionVideo, 'Codec', CodecId(FCodec));
    finally
      Ini.Free;
    end;
  except
    { Sem permissão de escrita: o app continua usando a configuração atual. }
  end;
end;

initialization
  AppConfig := TAppConfig.Create;

finalization
  AppConfig.Free;

end.
