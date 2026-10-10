unit uMain;

{ Interface principal: navegador (TEdgeBrowser) com barra de ferramentas
  estilo navegador e uma barra lateral de downloads com progresso real.

  Regra de ouro: NENHUM evento de navegador ou de download acessa a VCL
  diretamente fora da thread principal. Os handlers apenas registram flags e
  o TTimer (250 ms) lê esses flags e a fila de eventos do TDownloadManager na
  thread da interface. }

interface

uses
  Winapi.Windows,
  Winapi.ShellAPI,
  Winapi.ActiveX,
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.NetEncoding,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  Vcl.Graphics,
  Vcl.Dialogs,
  Vcl.Edge,
  Winapi.EdgeUtils,
  Winapi.WebView2,
  uDownloader;

type
  TDownloadItemView = class;

  TDownloadItemEvent = procedure(AItem: TDownloadItemView) of object;

  { Cartão de um download exibido na barra lateral. }
  TDownloadItemView = class(TPanel)
  private
    FTaskId: Integer;
    FKind: TDownloadKind;
    FFileName: string;
    FLblTitle: TLabel;
    FLblInfo: TLabel;
    FLblState: TLabel;
    FBar: TProgressBar;
    FBtnCancel: TButton;
    FBtnOpen: TButton;
    FOnCancel: TDownloadItemEvent;
    FOnOpen: TDownloadItemEvent;
    procedure CancelClick(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure DoResize(Sender: TObject);
  public
    constructor Create(AOwner: TComponent; const ATitle: string);
    procedure ApplyEvent(const AEvent: TDownloadEvent);
    procedure SetFailed(const AMessage: string);
    procedure SetCanceled;
    property TaskId: Integer read FTaskId;
    property Kind: TDownloadKind read FKind;
    property FileName: string read FFileName;
    property OnCancel: TDownloadItemEvent read FOnCancel write FOnCancel;
    property OnOpen: TDownloadItemEvent read FOnOpen write FOnOpen;
  end;

  TFrmMain = class(TForm)
  private
    FManager: TDownloadManager;
    FEdge: TEdgeBrowser;
    FToolbar: TPanel;
    FBtnBack: TButton;
    FBtnForward: TButton;
    FBtnReload: TButton;
    FBtnHome: TButton;
    FEdAddress: TEdit;
    FCbFormat: TComboBox;
    FBtnDownload: TButton;
    FBtnFolder: TButton;
    FLoadingBar: TProgressBar;
    FHost: TPanel;
    FSplitter: TSplitter;
    FSidebar: TPanel;
    FSbHeader: TPanel;
    FSbHint: TLabel;
    FDownloads: TScrollBox;
    FStatusBar: TStatusBar;
    FTicker: TTimer;
    FItems: TDictionary<Integer, TDownloadItemView>;

    FNavBusy: Boolean;
    FPendingTitle: string;
    FNewWindowUrl: string;
    FLastAddress: string;
    FClosing: Boolean;

    procedure BuildInterface;
    procedure BuildToolbar;
    procedure BuildSidebar;

    procedure ToolbarResize(Sender: TObject);

    procedure BtnBackClick(Sender: TObject);
    procedure BtnForwardClick(Sender: TObject);
    procedure BtnReloadClick(Sender: TObject);
    procedure BtnHomeClick(Sender: TObject);
    procedure BtnDownloadClick(Sender: TObject);
    procedure BtnFolderClick(Sender: TObject);
    procedure EdAddressKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);

    procedure EdgeCreateWebViewCompleted(Sender: TCustomEdgeBrowser; AResult: HResult);
    procedure EdgeNavigationStarting(Sender: TCustomEdgeBrowser;
      Args: TNavigationStartingEventArgs);
    procedure EdgeNavigationCompleted(Sender: TCustomEdgeBrowser;
      IsSuccess: Boolean; WebErrorStatus: COREWEBVIEW2_WEB_ERROR_STATUS);
    procedure EdgeDocumentTitleChanged(Sender: TCustomEdgeBrowser;
      const ADocumentTitle: string);
    procedure EdgeSourceChanged(Sender: TCustomEdgeBrowser; IsNewDocument: Boolean);
    procedure EdgeNewWindowRequested(Sender: TCustomEdgeBrowser;
      Args: TNewWindowRequestedEventArgs);

    procedure TickerTimer(Sender: TObject);
    function ResolveInput(const AText: string): string;
    procedure StartDownload;
    function EnsureItem(const ATask: TDownloadTask): TDownloadItemView;
    procedure ItemCancel(AItem: TDownloadItemView);
    procedure ItemOpen(AItem: TDownloadItemView);
    procedure UpdateNavigationState;
    procedure UpdateStatusBar;
    procedure WaitForActive(ATimeoutMs: Cardinal);

    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  FrmMain: TFrmMain;

const
  HOME_URL = 'https://www.youtube.com';
  SIDEBAR_WIDTH = 340;

implementation

{ ---------- Formatação ---------- }

function MakeEvent(AKind: TDownloadEventKind;
  const ATask: TDownloadTask): TDownloadEvent;
begin
  Result.Kind := AKind;
  Result.Task := ATask;
end;

function FormatBytes(AValue: Int64): string;
begin
  if AValue < 1024 then
    Result := Format('%d B', [AValue])
  else if AValue < Int64(1024) * 1024 then
    Result := FormatFloat('0.0', AValue / 1024) + ' KiB'
  else if AValue < Int64(1024) * 1024 * 1024 then
    Result := FormatFloat('0.0', AValue / (1024 * 1024)) + ' MiB'
  else
    Result := FormatFloat('0.00', AValue / (1024 * 1024 * 1024)) + ' GiB';
end;

function FormatSpeed(ABps: Int64): string;
begin
  if ABps <= 0 then
    Result := ''
  else
    Result := FormatBytes(ABps) + '/s';
end;

function FormatEta(AEta: Int64): string;
begin
  if AEta < 0 then
    Result := ''
  else if AEta < 60 then
    Result := Format('%ds', [AEta])
  else if AEta < 3600 then
    Result := Format('%dm%02ds', [AEta div 60, AEta mod 60])
  else
    Result := Format('%dh%02dm', [AEta div 3600, (AEta mod 3600) div 60]);
end;

{ ---------- TDownloadItemView ---------- }

constructor TDownloadItemView.Create(AOwner: TComponent; const ATitle: string);
begin
  inherited Create(AOwner);
  Parent := AOwner as TWinControl;
  BevelOuter := bvNone;
  ParentBackground := False;
  Color := $00FBFBFB;
  Height := 96;
  Align := alTop;
  Caption := '';

  FLblTitle := TLabel.Create(Self);
  FLblTitle.Parent := Self;
  FLblTitle.AutoSize := False;
  FLblTitle.Transparent := True;
  FLblTitle.EllipsisPosition := epEndEllipsis;
  FLblTitle.Font.Style := [fsBold];
  FLblTitle.Caption := ATitle;

  FBtnCancel := TButton.Create(Self);
  FBtnCancel.Parent := Self;
  FBtnCancel.Caption := '✕';
  FBtnCancel.OnClick := CancelClick;

  FBar := TProgressBar.Create(Self);
  FBar.Parent := Self;
  FBar.Min := 0;
  FBar.Max := 100;
  FBar.Style := pbstNormal;
  FBar.Smooth := True;

  FLblInfo := TLabel.Create(Self);
  FLblInfo.Parent := Self;
  FLblInfo.AutoSize := False;
  FLblInfo.Transparent := True;
  FLblInfo.Caption := 'Na fila…';

  FBtnOpen := TButton.Create(Self);
  FBtnOpen.Parent := Self;
  FBtnOpen.Caption := 'Abrir';
  FBtnOpen.Enabled := False;
  FBtnOpen.OnClick := OpenClick;

  FLblState := TLabel.Create(Self);
  FLblState.Parent := Self;
  FLblState.AutoSize := False;
  FLblState.Transparent := True;
  FLblState.Caption := '';

  OnResize := DoResize;
  DoResize(Self);
end;

procedure TDownloadItemView.DoResize(Sender: TObject);
var
  W: Integer;
begin
  W := ClientWidth;
  FLblTitle.SetBounds(10, 8, W - 44, 18);
  FBtnCancel.SetBounds(W - 30, 6, 24, 24);
  FBar.SetBounds(10, 30, W - 20, 14);
  FLblInfo.SetBounds(10, 48, W - 100, 16);
  FBtnOpen.SetBounds(W - 86, 46, 76, 24);
  FLblState.SetBounds(10, 70, W - 20, 16);
end;

procedure TDownloadItemView.CancelClick(Sender: TObject);
begin
  if Assigned(FOnCancel) then
    FOnCancel(Self);
end;

procedure TDownloadItemView.OpenClick(Sender: TObject);
begin
  if Assigned(FOnOpen) then
    FOnOpen(Self);
end;

procedure TDownloadItemView.ApplyEvent(const AEvent: TDownloadEvent);
var
  P: TDownloadProgress;
  Info: string;
begin
  FTaskId := AEvent.Task.Id;
  FKind := AEvent.Task.Kind;

  if AEvent.Task.Title <> '' then
    FLblTitle.Caption := AEvent.Task.Title;

  P := AEvent.Task.Progress;
  case AEvent.Kind of
    devProgress:
      begin
        if P.Percent >= 0 then
        begin
          if FBar.Style = pbstMarquee then
            FBar.Style := pbstNormal;
          FBar.Position := P.Percent;
        end
        else
          FBar.Style := pbstMarquee;

        Info := '';
        if P.Percent >= 0 then
          Info := Format('%d%%', [P.Percent]);
        if FormatSpeed(P.Bps) <> '' then
          Info := Info + '  •  ' + FormatSpeed(P.Bps);
        if FormatEta(P.Eta) <> '' then
          Info := Info + '  •  resta ' + FormatEta(P.Eta);
        if (Info = '') and (P.Phase <> '') then
          Info := P.Phase;
        FLblInfo.Caption := Info;

        FLblState.Caption := P.Phase;
        Color := $00FFF7E6;
      end;

    devDone:
      begin
        FBar.Style := pbstNormal;
        FBar.Position := 100;
        FFileName := AEvent.Task.FileName;
        FLblInfo.Caption := ExtractFileName(FFileName);
        FLblState.Caption := 'Concluído';
        Color := $00E8F8E8;
        FBtnCancel.Enabled := False;
        FBtnOpen.Enabled := FFileName <> '';
      end;

    devFailed:
      begin
        SetFailed(AEvent.Task.Error);
      end;

    devCanceled:
      begin
        SetCanceled;
      end;
  end;
end;

procedure TDownloadItemView.SetFailed(const AMessage: string);
begin
  FBar.Style := pbstNormal;
  FLblState.Caption := 'Erro: ' + AMessage;
  FLblInfo.Caption := '';
  Color := $00E6E6FA;
  FBtnCancel.Enabled := False;
  FBtnOpen.Enabled := False;
end;

procedure TDownloadItemView.SetCanceled;
begin
  FBar.Style := pbstNormal;
  FLblState.Caption := 'Cancelado';
  FLblInfo.Caption := '';
  Color := $00EDEDED;
  FBtnCancel.Enabled := False;
  FBtnOpen.Enabled := False;
end;

{ ---------- TFrmMain ---------- }

constructor TFrmMain.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);

  Caption := 'Clip Downloader - yt-dlp';
  Width := 1180;
  Height := 760;
  Position := poScreenCenter;

  FItems := TDictionary<Integer, TDownloadItemView>.Create;

  BuildInterface;

  FManager := TDownloadManager.Create;

  FTicker := TTimer.Create(Self);
  FTicker.Interval := 250;
  FTicker.OnTimer := TickerTimer;
  FTicker.Enabled := True;

  OnCloseQuery := FormCloseQuery;
  OnDestroy := FormDestroy;
  OnShow := FormShow;

  UpdateStatusBar;
end;

procedure TFrmMain.BuildInterface;
begin
  FStatusBar := TStatusBar.Create(Self);
  FStatusBar.Parent := Self;
  FStatusBar.SimplePanel := True;
  FStatusBar.SimpleText := 'Pronto.';

  FToolbar := TPanel.Create(Self);
  FToolbar.Parent := Self;
  FToolbar.Align := alTop;
  FToolbar.Height := 50;
  FToolbar.BevelOuter := bvNone;
  FToolbar.Color := $00F2F2F2;
  FToolbar.ParentBackground := False;
  BuildToolbar;

  FLoadingBar := TProgressBar.Create(Self);
  FLoadingBar.Parent := Self;
  FLoadingBar.Align := alTop;
  FLoadingBar.Height := 4;
  FLoadingBar.Min := 0;
  FLoadingBar.Max := 100;
  FLoadingBar.Style := pbstMarquee;
  FLoadingBar.Visible := False;

  { Host central: navegador à esquerda, splitter e barra lateral à direita.
    Ordem de criação: navegador (alClient) primeiro; splitter e barra lateral
    (alRight) em seguida, resultando na barra lateral na extrema direita. }
  FHost := TPanel.Create(Self);
  FHost.Parent := Self;
  FHost.Align := alClient;
  FHost.BevelOuter := bvNone;

  FEdge := TEdgeBrowser.Create(FHost);
  FEdge.Parent := FHost;
  FEdge.Align := alClient;
  FEdge.OnCreateWebViewCompleted := EdgeCreateWebViewCompleted;
  FEdge.OnNavigationStarting := EdgeNavigationStarting;
  FEdge.OnNavigationCompleted := EdgeNavigationCompleted;
  FEdge.OnDocumentTitleChanged := EdgeDocumentTitleChanged;
  FEdge.OnSourceChanged := EdgeSourceChanged;
  FEdge.OnNewWindowRequested := EdgeNewWindowRequested;

  { A barra lateral deve ficar na extrema direita. Para isso ela é criada
    ANTES do splitter: no AlignControls, quando os dois têm Align=alRight e o
    splitter entra na lista de alinhamento depois, ele é posicionado à
    esquerda da barra lateral. }
  FSidebar := TPanel.Create(FHost);
  FSidebar.Parent := FHost;
  FSidebar.Align := alRight;
  FSidebar.Width := SIDEBAR_WIDTH;
  FSidebar.BevelOuter := bvNone;
  FSidebar.Color := $00FAFAFA;
  FSidebar.ParentBackground := False;
  BuildSidebar;

  FSplitter := TSplitter.Create(FHost);
  FSplitter.Parent := FHost;
  FSplitter.Align := alRight;
  FSplitter.Width := 5;
end;

procedure TFrmMain.BuildToolbar;
begin
  FBtnBack := TButton.Create(FToolbar);
  FBtnBack.Parent := FToolbar;
  FBtnBack.SetBounds(8, 10, 34, 30);
  FBtnBack.Caption := '◀';
  FBtnBack.Font.Name := 'Segoe UI Symbol';
  FBtnBack.OnClick := BtnBackClick;

  FBtnForward := TButton.Create(FToolbar);
  FBtnForward.Parent := FToolbar;
  FBtnForward.SetBounds(46, 10, 34, 30);
  FBtnForward.Caption := '▶';
  FBtnForward.Font.Name := 'Segoe UI Symbol';
  FBtnForward.OnClick := BtnForwardClick;

  FBtnReload := TButton.Create(FToolbar);
  FBtnReload.Parent := FToolbar;
  FBtnReload.SetBounds(84, 10, 34, 30);
  FBtnReload.Caption := '⟳';
  FBtnReload.Font.Name := 'Segoe UI Symbol';
  FBtnReload.OnClick := BtnReloadClick;

  FBtnHome := TButton.Create(FToolbar);
  FBtnHome.Parent := FToolbar;
  FBtnHome.SetBounds(122, 10, 34, 30);
  FBtnHome.Caption := '⌂';
  FBtnHome.Font.Name := 'Segoe UI Symbol';
  FBtnHome.OnClick := BtnHomeClick;

  FEdAddress := TEdit.Create(FToolbar);
  FEdAddress.Parent := FToolbar;
  FEdAddress.SetBounds(166, 12, 560, 26);
  FEdAddress.TextHint := 'Pesquise no YouTube ou cole um link';
  FEdAddress.OnKeyDown := EdAddressKeyDown;
  FEdAddress.Text:='https://www.youtube.com/watch?v=LAJkL4dZpzk&list=RDLAJkL4dZpzk&start_radio=1';

  FCbFormat := TComboBox.Create(FToolbar);
  FCbFormat.Parent := FToolbar;
  FCbFormat.SetBounds(738, 12, 170, 26);
  FCbFormat.Style := csDropDownList;
  FCbFormat.Items.Add('MP3 (áudio 320 kbps)');
  FCbFormat.Items.Add('MP4 (vídeo 720p)');
  FCbFormat.ItemIndex := 0;

  FBtnDownload := TButton.Create(FToolbar);
  FBtnDownload.Parent := FToolbar;
  FBtnDownload.SetBounds(916, 11, 120, 28);
  FBtnDownload.Caption := 'Baixar';
  FBtnDownload.Font.Style := [fsBold];
  FBtnDownload.OnClick := BtnDownloadClick;

  FBtnFolder := TButton.Create(FToolbar);
  FBtnFolder.Parent := FToolbar;
  FBtnFolder.SetBounds(1042, 11, 110, 28);
  FBtnFolder.Caption := 'Pasta';
  FBtnFolder.OnClick := BtnFolderClick;

  FToolbar.OnResize := ToolbarResize;
end;

procedure TFrmMain.ToolbarResize(Sender: TObject);
begin
  FBtnFolder.Left := FToolbar.ClientWidth - 118;
  FBtnDownload.Left := FBtnFolder.Left - 128;
  FCbFormat.Left := FBtnDownload.Left - 178;
  FEdAddress.Width := FCbFormat.Left - FEdAddress.Left - 8;
  if FEdAddress.Width < 120 then
    FEdAddress.Width := 120;
end;

procedure TFrmMain.BuildSidebar;
begin
  FSbHeader := TPanel.Create(FSidebar);
  FSbHeader.Parent := FSidebar;
  FSbHeader.Align := alTop;
  FSbHeader.Height := 46;
  FSbHeader.BevelOuter := bvNone;
  FSbHeader.Color := $00E8E8E8;
  FSbHeader.ParentBackground := False;
  FSbHeader.Caption := '  Downloads';
  FSbHeader.Alignment := taLeftJustify;
  FSbHeader.Font.Style := [fsBold];

  FSbHint := TLabel.Create(FSidebar);
  FSbHint.Parent := FSidebar;
  FSbHint.Align := alBottom;
  FSbHint.Height := 40;
  FSbHint.Transparent := True;
  FSbHint.WordWrap := True;
  FSbHint.Caption := '  Abra um vídeo e clique em "Baixar".';

  FDownloads := TScrollBox.Create(FSidebar);
  FDownloads.Parent := FSidebar;
  FDownloads.Align := alClient;
  FDownloads.BorderStyle := bsNone;
  FDownloads.VertScrollBar.Tracking := True;
end;

{ ---------- Navegação ---------- }

function TFrmMain.ResolveInput(const AText: string): string;
var
  S: string;
begin
  S := Trim(AText);
  if S = '' then
    Exit(HOME_URL);

  if (Pos(' ', S) > 0) or (Pos('.', S) = 0) then
    Exit('https://www.youtube.com/results?search_query=' +
      TNetEncoding.URL.EncodeQuery(S));

  if (Pos('://', S) = 0) then
    S := 'https://' + S;
  Result := S;
end;

procedure TFrmMain.EdAddressKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    Key := 0;
    FEdge.Navigate(ResolveInput(FEdAddress.Text));
  end;
end;

procedure TFrmMain.BtnBackClick(Sender: TObject);
begin
  FEdge.GoBack;
end;

procedure TFrmMain.BtnForwardClick(Sender: TObject);
begin
  FEdge.GoForward;
end;

procedure TFrmMain.BtnReloadClick(Sender: TObject);
begin
  if FNavBusy then
    FEdge.Stop
  else
    FEdge.Refresh;
end;

procedure TFrmMain.BtnHomeClick(Sender: TObject);
begin
  FEdge.Navigate(HOME_URL);
end;

procedure TFrmMain.BtnFolderClick(Sender: TObject);
begin
  ForceDirectories(DEST_DIR);
  ShellExecute(Handle, 'open', PChar(DEST_DIR), nil, nil, SW_SHOWNORMAL);
end;

procedure TFrmMain.EdgeCreateWebViewCompleted(Sender: TCustomEdgeBrowser;
  AResult: HResult);
begin
  if Succeeded(AResult) then
    FNewWindowUrl := HOME_URL
  else
    FPendingTitle := 'ERRO_WEBVIEW';
end;

procedure TFrmMain.EdgeNavigationStarting(Sender: TCustomEdgeBrowser;
  Args: TNavigationStartingEventArgs);
begin
  FNavBusy := True;
end;

procedure TFrmMain.EdgeNavigationCompleted(Sender: TCustomEdgeBrowser;
  IsSuccess: Boolean; WebErrorStatus: COREWEBVIEW2_WEB_ERROR_STATUS);
begin
  FNavBusy := False;
end;

procedure TFrmMain.EdgeDocumentTitleChanged(Sender: TCustomEdgeBrowser;
  const ADocumentTitle: string);
begin
  FPendingTitle := ADocumentTitle;
end;

procedure TFrmMain.EdgeSourceChanged(Sender: TCustomEdgeBrowser;
  IsNewDocument: Boolean);
begin
  { Evento pode vir de thread secundária; apenas sinaliza atualização. }
  if IsNewDocument then
    FLastAddress := '';
end;

procedure TFrmMain.EdgeNewWindowRequested(Sender: TCustomEdgeBrowser;
  Args: TNewWindowRequestedEventArgs);
var
  Uri: PWideChar;
begin
  Uri := nil;
  if Succeeded(Args.ArgsInterface.Get_uri(Uri)) and (Uri <> nil) then
  begin
    FNewWindowUrl := Uri;
    CoTaskMemFree(Uri);
    Args.ArgsInterface.Set_Handled(1);
  end;
end;

procedure TFrmMain.UpdateNavigationState;
begin
  if FNavBusy then
  begin
    FLoadingBar.Style := pbstMarquee;
    FLoadingBar.Visible := True;
    FBtnReload.Caption := '✕';
  end
  else
  begin
    FLoadingBar.Visible := False;
    FBtnReload.Caption := '⟳';
  end;

  if FEdge.WebViewCreated then
  begin
    FBtnBack.Enabled := FEdge.CanGoBack;
    FBtnForward.Enabled := FEdge.CanGoForward;
  end;

  if (FPendingTitle <> '') and (FPendingTitle <> 'ERRO_WEBVIEW') and
    (not FEdAddress.Focused) then
  begin
    FLastAddress := FEdge.LocationURL;
    if FLastAddress <> '' then
      FEdAddress.Text := FLastAddress;
  end;
end;

{ ---------- Download ---------- }

procedure TFrmMain.BtnDownloadClick(Sender: TObject);
begin
  if not FileExists(YTDLP_EXE) then
  begin
    ShowMessage('yt-dlp.exe não encontrado em:' + sLineBreak + YTDLP_EXE);
    Exit;
  end;
  if (FCbFormat.ItemIndex = 1) and (not FileExists(FFMPEG_EXE)) then
  begin
    ShowMessage('ffmpeg.exe não encontrado em:' + sLineBreak + FFMPEG_EXE);
    Exit;
  end;
  StartDownload;
end;

procedure TFrmMain.StartDownload;
var
  Url, VideoId: string;
  Kind: TDownloadKind;
  Task: TDownloadTask;
  Duplicate: Boolean;
  Item: TDownloadItemView;
begin
  Url := FEdge.LocationURL;
  if Url = '' then
    Url := FEdAddress.Text;

  TDownloadManager.NormalizeUrl(Url, VideoId);
  if VideoId = '' then
  begin
    ShowMessage('Abra um vídeo do YouTube (watch, shorts ou youtu.be) ' +
      'antes de baixar.' + sLineBreak + sLineBreak +
      'URL atual: ' + Url);
    Exit;
  end;

  if FCbFormat.ItemIndex = 1 then
    Kind := dkMp4
  else
    Kind := dkMp3;

  if not FManager.Enqueue(Url, Kind, Task, Duplicate) then
  begin
    if Duplicate then
      ShowMessage('Este vídeo já está na fila ou foi concluído.');
    Exit;
  end;

  Item := TDownloadItemView.Create(FDownloads,
    Format('Download #%d (aguardando…)', [Task.Id]));
  Item.ApplyEvent(MakeEvent(devProgress, Task));
  Item.OnCancel := ItemCancel;
  Item.OnOpen := ItemOpen;
  FItems.Add(Task.Id, Item);

  FManager.Pump;
  UpdateStatusBar;
  FSbHint.Caption := Format('  1 download na fila (#%d)', [Task.Id]);
end;

function TFrmMain.EnsureItem(const ATask: TDownloadTask): TDownloadItemView;
begin
  if not FItems.TryGetValue(ATask.Id, Result) then
  begin
    Result := TDownloadItemView.Create(FDownloads,
      Format('Download #%d', [ATask.Id]));
    Result.OnCancel := ItemCancel;
    Result.OnOpen := ItemOpen;
    FItems.Add(ATask.Id, Result);
  end;
end;

procedure TFrmMain.ItemCancel(AItem: TDownloadItemView);
begin
  FManager.Cancel(AItem.TaskId);
  FStatusBar.SimpleText := Format('Cancelando download #%d…', [AItem.TaskId]);
end;

procedure TFrmMain.ItemOpen(AItem: TDownloadItemView);
begin
  if (AItem.FileName <> '') and FileExists(AItem.FileName) then
    ShellExecute(Handle, 'open', PChar(AItem.FileName), nil, nil, SW_SHOWNORMAL)
  else
    BtnFolderClick(nil);
end;

{ ---------- Ticker / eventos ---------- }

procedure TFrmMain.TickerTimer(Sender: TObject);
var
  Events: TArray<TDownloadEvent>;
  I: Integer;
  Item: TDownloadItemView;
begin
  if FNewWindowUrl <> '' then
  begin
    FEdge.Navigate(FNewWindowUrl);
    FNewWindowUrl := '';
  end;

  if FPendingTitle = 'ERRO_WEBVIEW' then
  begin
    FPendingTitle := '';
    ShowMessage('Não foi possível iniciar o WebView2.' + sLineBreak +
      'Verifique se o Microsoft Edge WebView2 Runtime está instalado e se ' +
      'o arquivo WebView2Loader.dll está ao lado do executável.');
  end
  else if (FPendingTitle <> '') and (not FEdAddress.Focused) then
  begin
    Caption := FPendingTitle + ' - Clip Downloader';
  end;

  if FManager.DrainEvents(Events) > 0 then
  begin
    for I := Low(Events) to High(Events) do
    begin
      Item := EnsureItem(Events[I].Task);
      Item.ApplyEvent(Events[I]);
    end;
    UpdateStatusBar;
  end;

  UpdateNavigationState;
end;

procedure TFrmMain.UpdateStatusBar;
begin
  FStatusBar.SimpleText := Format(
    'Pendentes: %d   •   Baixando: %d   •   Concluídos: %d   •   ' +
    'Cancelados: %d   •   Erros: %d',
    [FManager.PendingCount, FManager.ActiveCount, FManager.DoneCount,
    FManager.CancelledCount, FManager.FailedCount]);
end;

procedure TFrmMain.WaitForActive(ATimeoutMs: Cardinal);
var
  StartTick: Cardinal;
begin
  StartTick := GetTickCount;
  while (FManager.ActiveCount > 0) and
    (GetTickCount - StartTick < ATimeoutMs) do
    Sleep(30);
end;

{ ---------- Fechamento ---------- }

procedure TFrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FClosing then
  begin
    CanClose := True;
    Exit;
  end;

  if (FManager <> nil) and (FManager.ActiveCount > 0) then
  begin
    CanClose := False;
    if MessageDlg(Format('Existem %d download(s) em andamento.%s' +
      'Deseja cancelá-los e sair?', [FManager.ActiveCount, sLineBreak]),
      mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    begin
      FClosing := True;
      FManager.Halt;
      FManager.StopAll;
      WaitForActive(30000);
      Close;
    end;
  end
  else
    CanClose := True;
end;

procedure TFrmMain.FormDestroy(Sender: TObject);
begin
  if FTicker <> nil then
  begin
    FTicker.Enabled := False;
    FreeAndNil(FTicker);
  end;

  if FEdge <> nil then
    FEdge.CloseBrowserProcess;

  if FManager <> nil then
  begin
    FManager.Halt;
    FManager.StopAll;
    WaitForActive(30000);
    FreeAndNil(FManager);
  end;

  FreeAndNil(FItems);
end;

procedure TFrmMain.FormShow(Sender: TObject);
begin
  FEdge.CreateWebView;
end;

initialization
  SetWebView2Path(ExtractFilePath(ParamStr(0)) + 'WebView2Loader.dll');

end.
