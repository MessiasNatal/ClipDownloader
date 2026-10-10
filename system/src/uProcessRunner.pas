unit uProcessRunner;

{ Executa um processo externo de forma segura, consumindo stdout e stderr
  sem deadlock (leitura feita por uma thread dedicada) e permitindo o
  cancelamento a qualquer momento (encerra o processo externo).

  As linhas de saída são entregues pelo evento OnLine. Nenhuma chamada a
  componentes visuais deve ser feita dentro desses eventos. }

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.SyncObjs;

type
  TProcessOutputEvent = procedure(Sender: TObject; const ALine: string) of object;

  TProcessRunner = class
  private type
    TOutputReader = class(TThread)
    private
      FOwner: TProcessRunner;
    protected
      procedure Execute; override;
    end;
  private
    FExe: string;
    FParams: string;
    FWorkDir: string;
    FOnLine: TProcessOutputEvent;
    FReader: TOutputReader;
    FProcessHandle: THandle;
    FThreadHandle: THandle;
    FReadHandle: THandle;
    FWriteHandle: THandle;
    FRequestCancel: Integer;
    FExitCode: Cardinal;

    procedure DispatchLine(const ALine: string);
    function GetIsCancelled: Boolean;
  public
    constructor Create(const AExe, AParams, AWorkDir: string);
    destructor Destroy; override;

    { Executa o processo de forma síncrona. Retorna True se o processo foi
      iniciado (mesmo que o exit code seja diferente de zero). As linhas de
      saída são entregues em OnLine. }
    function Run: Boolean;

    { Solicita o encerramento do processo. Pode ser chamado de qualquer thread. }
    procedure Cancel;

    property ExitCode: Cardinal read FExitCode;
    property IsCancelled: Boolean read GetIsCancelled;
    property OnLine: TProcessOutputEvent read FOnLine write FOnLine;
  end;

implementation

{ Extrai a primeira linha completa (finalizada por CR e/ou LF) do início do
  buffer. Retorna False quando não há linha completa. }
function ExtractLine(var AText: string; out ALine: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  I := 1;
  while I <= Length(AText) do
  begin
    if (AText[I] = #13) or (AText[I] = #10) then
    begin
      ALine := Copy(AText, 1, I - 1);
      Delete(AText, 1, I);
      if (AText <> '') and ((AText[1] = #13) or (AText[1] = #10)) then
        Delete(AText, 1, 1);
      Result := True;
      Exit;
    end;
    Inc(I);
  end;
end;

{ TProcessRunner.TOutputReader }

procedure TProcessRunner.TOutputReader.Execute;
var
  Buffer: TBytes;
  BytesRead: Cardinal;
  Pending, Text, Line: string;
begin
  SetLength(Buffer, 65536);
  Pending := '';
  try
    while not Terminated do
    begin
      BytesRead := 0;
      if not ReadFile(FOwner.FReadHandle, Pointer(Buffer)^, Length(Buffer),
        BytesRead, nil) then
        Break;
      if BytesRead = 0 then
        Break;
      Text := TEncoding.UTF8.GetString(Buffer, 0, Integer(BytesRead));
      Pending := Pending + Text;
      while ExtractLine(Pending, Line) do
        FOwner.DispatchLine(Line);
    end;
    if Pending <> '' then
      FOwner.DispatchLine(Pending);
  except
    on E: Exception do
      ; { Ignora erros de leitura: o canal foi fechado ou o fluxo terminou. }
  end;
end;

{ TProcessRunner }

constructor TProcessRunner.Create(const AExe, AParams, AWorkDir: string);
begin
  inherited Create;
  FExe := AExe;
  FParams := AParams;
  FWorkDir := AWorkDir;
  FExitCode := Cardinal(-1);
  FProcessHandle := 0;
  FThreadHandle := 0;
  FReadHandle := 0;
  FWriteHandle := 0;
end;

destructor TProcessRunner.Destroy;
begin
  if FProcessHandle <> 0 then
  begin
    TerminateProcess(FProcessHandle, 1);
    CloseHandle(FProcessHandle);
  end;
  if FReader <> nil then
  begin
    FReader.Terminate;
    FReader.Free;
  end;
  if FThreadHandle <> 0 then
    CloseHandle(FThreadHandle);
  if FWriteHandle <> 0 then
    CloseHandle(FWriteHandle);
  if FReadHandle <> 0 then
    CloseHandle(FReadHandle);
  inherited Destroy;
end;

procedure TProcessRunner.DispatchLine(const ALine: string);
begin
  if Assigned(FOnLine) then
    FOnLine(Self, ALine);
end;

function TProcessRunner.GetIsCancelled: Boolean;
begin
  Result := FRequestCancel <> 0;
end;

procedure TProcessRunner.Cancel;
begin
  TInterlocked.Exchange(FRequestCancel, 1);
  if FProcessHandle <> 0 then
    TerminateProcess(FProcessHandle, 1);
end;

function TProcessRunner.Run: Boolean;
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
  InHandle: THandle;
  Cmd: string;
begin
  Result := False;
  FExitCode := Cardinal(-1);

  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  SA.lpSecurityDescriptor := nil;

  { Entrada padrão: NUL (o processo filho enxerga EOF no stdin). }
  InHandle := CreateFile('NUL', GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, @SA, OPEN_EXISTING, 0, 0);
  if InHandle = INVALID_HANDLE_VALUE then
    Exit;
  SetHandleInformation(InHandle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);

  try
    if not CreatePipe(FReadHandle, FWriteHandle, @SA, 0) then
      Exit;
    try
      { Somente a ponta de escrita é herdada pelo filho; assim o fim do fluxo
        (EOF) é detectado quando todas as pontas de escrita forem fechadas. }
      SetHandleInformation(FReadHandle, HANDLE_FLAG_INHERIT, 0);

      ZeroMemory(@SI, SizeOf(SI));
      ZeroMemory(@PI, SizeOf(PI));
      SI.cb := SizeOf(SI);
      SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
      SI.wShowWindow := SW_HIDE;
      SI.hStdInput := InHandle;
      SI.hStdOutput := FWriteHandle;
      SI.hStdError := FWriteHandle;

      Cmd := '"' + FExe + '"';
      if FParams <> '' then
        Cmd := Cmd + ' ' + FParams;
      UniqueString(Cmd);

      if not CreateProcess(nil, PChar(Cmd), nil, nil, True,
        CREATE_NO_WINDOW, nil, PChar(FWorkDir), SI, PI) then
        Exit;

      CloseHandle(FWriteHandle);
      FWriteHandle := 0;
      FProcessHandle := PI.hProcess;
      FThreadHandle := PI.hThread;

      FReader := TOutputReader.Create(True);
      FReader.FreeOnTerminate := False;
      FReader.FOwner := Self;
      FReader.Start;

      try
        while True do
        begin
          if FRequestCancel <> 0 then
            TerminateProcess(FProcessHandle, 1);
          if WaitForSingleObject(FProcessHandle, 100) = WAIT_OBJECT_0 then
            Break;
        end;
        GetExitCodeProcess(FProcessHandle, FExitCode);
      finally
        CloseHandle(FProcessHandle);
        FProcessHandle := 0;

        { Espera a thread leitora consumir toda a saída (o processo já saiu e
          fechou suas pontas, garantindo o EOF). }
        if FReader <> nil then
        begin
          FReader.WaitFor;
          FReader.Free;
          FReader := nil;
        end;
        if FThreadHandle <> 0 then
        begin
          CloseHandle(FThreadHandle);
          FThreadHandle := 0;
        end;
      end;

      Result := True;
    finally
      if FWriteHandle <> 0 then
      begin
        CloseHandle(FWriteHandle);
        FWriteHandle := 0;
      end;
      if FReadHandle <> 0 then
      begin
        CloseHandle(FReadHandle);
        FReadHandle := 0;
      end;
    end;
  finally
    CloseHandle(InHandle);
  end;
end;

end.