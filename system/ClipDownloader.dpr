program ClipDownloader;

uses
  Vcl.Forms,
  uConfig in 'src\uConfig.pas',
  uProcessRunner in 'src\uProcessRunner.pas',
  uDownloader in 'src\uDownloader.pas',
  uMain in 'src\uMain.pas',
  Vcl.Themes,
  Vcl.Styles;

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  TStyleManager.TrySetStyle('Windows11 Modern Dark');
  Application.CreateForm(TFrmMain, FrmMain);
  Application.Run;
end.
