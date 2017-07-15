program vtxserv;

{$codepage utf8}
{$mode objfpc}{$H+}
{$apptype console}

uses
  cmem,
{$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
{$ENDIF}{$ENDIF}

  // pascal / os stuff
  {$IFDEF WINDOWS}
    Windows, {for setconsoleoutputcp}
  {$ENDIF}
  Classes, Process, Pipes, DateUtils, SysUtils, IniFiles, Crt,
  LConvEncoding,

  // network stuff
  BlckSock, Sockets, Synautil, Laz_Synapse, WebSocket2, CustomServer2;


const
  CRLF = #13#10;

type
  TvtxHTTPServer =    class;  // very basic web server for dishing out client
  TvtxWSServer =      class;  // quasi robust websocket server
  TvtxIOBridge =      class;
  TvtxWSConnection =  class;  // websocket connection spawns consoles per connection
  TvtxProcessNanny =  class;

  TvtxProgressEvent = procedure(ip, msg: string) of object;

  { TvtxHTTPServer : for basic webserver front end for dishing out client }
  TvtxHTTPServer = class(TThread)
    private
      fProgress :   string;
      fOnProgress : TvtxProgressEvent;
      procedure     DoProgress;

    protected
      procedure     Execute; override;
      procedure     AttendConnection(ASocket : TTCPBlockSocket);
      function      SendFile(
                      ASocket : TTCPBlockSocket;
                      ContentType : string;
                      Filename : string) : integer;
      function      SendImage(
                      ASocket : TTCPBlockSocket;
                      ContentType : string;
                      Filename : string) : integer;

    public
      constructor   Create(CreateSuspended: boolean);
      destructor    Destroy; override;
      property      OnProgress : TvtxProgressEvent
                      read fOnProgress
                      write fOnProgress;
  end;

  { TvtxIOBridge : these are for the background worker that routes stdout from
    client processes to websocket output and input from websocket to stdin of
    client processes. }
  TvtxIOBridge = class(TThread)
    private
      fProgress :     string;
      fOnProgress:    TvtxProgressEvent;
      procedure       DoProgress;

    protected
      procedure       Execute; override;
      procedure       PipeToConn(
                        input : TInputPipeStream;
                        conn : TvtxWSConnection);
      procedure       PipeToLocal(input : TInputPipeStream);

    public
      constructor     Create(CreateSuspended : boolean);
      destructor      Destroy; override;
      property        OnProgress : TvtxProgressEvent
                        read fOnProgress
                        write fOnProgress;
  end;

  { TvtxWSServer : websocket server class object }
  TvtxWSServer = class(TWebSocketServer)
    public
      function GetWebSocketConnectionClass(
                Socket: TTCPCustomConnectionSocket;
                Header: TStringList;
                ResourceName, sHost, sPort, Origin, Cookie: string;
            out HttpResult: integer;
            var Protocol, Extensions: string) : TWebSocketServerConnections; override;
  end;

  { TvtxProcessNanny : thread for spawning connection console. terminate
    connection on exit }
  TvtxProcessNanny = class(TThread)
    private
      fProgress : string;
      fOnProgress : TvtxProgressEvent;
      procedure DoProgress;

    protected
      procedure Execute; override;

    public
      serverCon : TvtxWSConnection;
      constructor Create(CreateSuspended: boolean);
      destructor  Destroy; override;
      property    OnProgress: TvtxProgressEvent read fOnProgress write fOnProgress;
  end;

  { TvtxWSConnection : Websocket connection class. }
  TvtxWSConnection = class(TWebSocketServerConnection)
    public
      ExtNanny   :  TvtxProcessNanny; // the TThread that runs below ExtProcess
      ExtProcess :  TProcess;         // the TProcess spawned board

      property ReadFinal: boolean read fReadFinal;
      property ReadRes1: boolean read fReadRes1;
      property ReadRes2: boolean read fReadRes2;
      property ReadRes3: boolean read fReadRes3;
      property ReadCode: integer read fReadCode;
      property ReadStream: TMemoryStream read fReadStream;

      property WriteFinal: boolean read fWriteFinal;
      property WriteRes1: boolean read fWriteRes1;
      property WriteRes2: boolean read fWriteRes2;
      property WriteRes3: boolean read fWriteRes3;
      property WriteCode: integer read fWriteCode;
      property WriteStream: TMemoryStream read fWriteStream;
  end;

  { TvtxSystemInfo : Board Inofo record }
  TvtxSystemInfo = record
    SystemName :  string;   // name of bbs - webpage title
    SystemIP :    string;   // ip address of this host - needed to bind to socket
    InternetIP :  string;   // ip address as seen from internet
    HTTPPort :    string;   // port number for http front end
    WSPort :      string;   // port number for ws back end
    ExtProcess :  string;   // command line string for process to fork for connection
                            // messaged for @ codes prior to execution.
    MaxConnections : integer;
  end;

  { TvtxApp : Main application class }
  TvtxApp = class
    procedure StartHTTP;
    procedure StartWS;
    procedure StartBridge;
    procedure StopHTTP;
    procedure StopWS;
    procedure StopBridge;
    procedure WriteCon(ip, msg : string); register;
    procedure WSBeforeAddConnection(Server : TCustomServer; aConnection : TCustomConnection;var CanAdd : boolean); register;
    procedure WSAfterAddConnection(Server : TCustomServer; aConnection : TCustomConnection); register;
    procedure WSBeforeRemoveConnection(Server : TCustomServer; aConnection : TCustomConnection); register;
    procedure WSAfterRemoveConnection(Server : TCustomServer; aConnection : TCustomConnection); register;
    procedure WSSocketError(Server: TCustomServer; Socket: TTCPBlockSocket); register;
    procedure WSOpen(aSender: TWebSocketCustomConnection);
    procedure WSRead(aSender : TWebSocketCustomConnection; aFinal, aRes1, aRes2, aRes3 : boolean; aCode :integer; aData :TMemoryStream);
    procedure WSWrite(aSender : TWebSocketCustomConnection; aFinal, aRes1, aRes2, aRes3 : boolean; aCode :integer; aData :TMemoryStream);
    procedure WSClose(aSender: TWebSocketCustomConnection; aCloseCode: integer; aCloseReason: string; aClosedByPeer: boolean);
    procedure WSTerminate(Sender : TObject); register;

    procedure CloseAllNodes;
    procedure CloseNode(n : integer);

    procedure BridgeTerminate(Sender: TObject);
    procedure NannyTerminate(Sender: TObject);
    procedure HTTPTerminate(Sender : TObject); register;
  end;

  TServices = ( HTTP, WS, Bridge, All, Unknown );
  TServSet = set of TServices;

  // Code page stuff.

  TCodePages = (
    CP1250, CP1251, CP1252, CP1253,
    CP1254, CP1255, CP1256, CP1257,
    CP1258, CP437, CP850, CP852,
    CP866, CP874, CP932, CP936,
    CP949, CP950, MACINTOSH, KOI8 );
  TCodePageConverter = function(const s: string): string;

const
  FirstCP : TCodePages = CP1250;
  LastCP : TCodePages = KOI8;
  CodePageNames : array [ CP1250 .. KOI8 ] of string = (
    'CP1250', 'CP1251', 'CP1252', 'CP1253',
    'CP1254', 'CP1255', 'CP1256', 'CP1257',
    'CP1258', 'CP437', 'CP850', 'CP852',
    'CP866', 'CP874', 'CP932', 'CP936',
    'CP949', 'CP950', 'MACINTOSH', 'KOI8' );
  CodePageConverters : array [ CP1250 .. KOI8 ] of TCodePageConverter = (
    @CP1250ToUTF8, @CP1251ToUTF8, @CP1252ToUTF8, @CP1253ToUTF8,
    @CP1254ToUTF8, @CP1255ToUTF8, @CP1256ToUTF8, @CP1257ToUTF8,
    @CP1258ToUTF8, @CP437ToUTF8, @CP850ToUTF8, @CP852ToUTF8,
    @CP866ToUTF8, @CP874ToUTF8, @CP932ToUTF8, @CP936ToUTF8,
    @CP949ToUTF8, @CP950ToUTF8, @MACINTOSHToUTF8, @KOI8ToUTF8 );

function Convert(cp : TCodePages; filename : string) : string; register;
  var
    fin : TextFile;
    linein : RawByteString;
    str : string;
  begin
    result := '';
    str := '';
    if fileexists(filename) then
    begin
      assign(fin, filename);
      reset(fin);
      while not eof(fin) do
      begin
        readln(fin, linein);
        str += CodePageConverters[cp](linein) + CRLF;
      end;
      closefile(fin);
      result := str;
    end;
  end;


procedure LoadSettings; forward;
function GetSocketErrorMsg(errno : integer) : string; forward;
function GetServFromWords(word : TStringArray) : TServSet; forward;
function ConsoleLineIn : string; forward;

var
  app :         TvtxApp;

  lastaction :  TDateTime;      // last time activity

  serverWS :    TvtxWSServer;   // ws server.
  serverHTTP :  TvtxHTTPServer; // http srever.
  bridgeWS :    TvtxIOBridge;   // bridge streams.

  runningWS,
  runningHTTP,
  runningBridge: boolean;

  SystemInfo :    TvtxSystemInfo;

{ TvtxIOBridge }

constructor TvtxIOBridge.Create(CreateSuspended: boolean);
  begin
    fProgress := '';
    FreeOnTerminate := True;
    inherited Create(CreateSuspended);
  end;

destructor TvtxIOBridge.Destroy;
  begin
    inherited Destroy;
  end;

procedure TvtxIOBridge.DoProgress;
  begin
    if Assigned(FOnProgress) then
    begin
      FOnProgress('', fProgress);
    end;
  end;

procedure TvtxIOBridge.PipeToConn(input : TInputPipeStream; conn : TvtxWSConnection);
  var
    i, bytes : integer;
    b : byte;
    str : ansistring;
  begin
    try
      bytes := input.NumBytesAvailable;
    except
      bytes := 0;
    end;

    str := '';
    if bytes > 0 then
    begin
      lastaction := now;
      for i := 0 to bytes - 1 do
      begin
        try
          b := input.ReadByte;
        finally
          str += char(b);
        end;
      end;
      conn.SendText(str);
    end;
  end;

procedure TvtxIOBridge.PipeToLocal(input : TInputPipeStream);
  var
    i, bytes : integer;
    b : byte;
    str : ansistring;
  begin
    try
      bytes := input.NumBytesAvailable;
    except
      bytes := 0;
    end;

    str := '';
    if bytes > 0 then
    begin
      lastaction := now;
      for i := 0 to bytes - 1 do
      begin
        try
          b := input.ReadByte;
        finally
          str += char(b);
        end;
      end;
      fProgress := str;
      Synchronize(@DoProgress);
    end;
  end;

procedure TvtxIOBridge.Execute;
  var
    i : integer;
    conn : TvtxWSConnection;
  begin
    // for each connect that has process, send input, read output
    repeat
      if not serverWS.CheckTerminated then
      begin
        for i := 0 to serverWS.Count - 1 do
        begin
          lastaction := now;  // there are active connections
          conn := TvtxWSConnection(serverWS.Connection[i]);

          if not conn.Closed then
          begin
            if conn.ExtProcess <> nil then
            begin

              // send console stdout to websocket connection
              if conn.ExtProcess.Output <> nil then
                PipeToConn(conn.ExtProcess.Output, conn);

              // send console stderr to websocket connection
              if conn.ExtProcess.Stderr <> nil then
              begin
                // pipe this to writecon
                PipeToLocal(conn.ExtProcess.Stderr);
              end;
            end;
          end;
        end;
      end;

      // keep this thread from smoking the system
      sleep(25);

      if Terminated then
        break;

    until false;
    //fProgress := 'Bridge Terminating.';
    //Synchronize(@DoProgress);
  end;


{ TvtxHTTPServer }

constructor TvtxHTTPServer.Create(CreateSuspended: boolean);
begin
  fProgress := '';
  FreeOnTerminate := True;
  inherited Create(CreateSuspended);
end;

destructor TvtxHTTPServer.Destroy;
begin
  inherited Destroy;
end;

procedure TvtxHTTPServer.DoProgress;
begin
  if Assigned(FOnProgress) then
  begin
    FOnProgress('', fProgress);
  end;
end;

// main http listener loop
procedure TvtxHTTPServer.Execute;
var
  ListenerSocket,
  ConnectionSocket: TTCPBlockSocket;
  errno : integer;
begin
  begin
    ListenerSocket := TTCPBlockSocket.Create;
    ConnectionSocket := TTCPBlockSocket.Create;

    // not designed to run on high performance production servers
    // give users all the time they need.
    try
      ListenerSocket.CreateSocket;
      ListenerSocket.SetTimeout(10000);
      ListenerSocket.SetLinger(true, 10000);
      ListenerSocket.Bind(SystemInfo.SystemIP, SystemInfo.HTTPPort);
      ListenerSocket.Listen;
    finally
      repeat
        if ListenerSocket.CanRead(1000) then
        begin
          lastaction := now;  // there are active connections

          // todo: thread this out.
          ConnectionSocket.Socket := ListenerSocket.Accept;
          errno := ConnectionSocket.LastError;
          if errno <> 0 then
          begin
            fProgress := Format(
                '** Error HTTP accepting socket. #%d : %s',
                [ errno, GetSocketErrorMsg(errno) ]);
            Synchronize(@DoProgress);
          end
          else
          begin
            AttendConnection(ConnectionSocket);
            ConnectionSocket.CloseSocket;
          end;
        end;
        if Terminated then
          break;
      until false;
    end;
    ListenerSocket.Free;
    ConnectionSocket.Free;
  end;
end;

// send an image from www directory
function TvtxHTTPServer.SendImage(
          ASocket : TTCPBlockSocket;
          ContentType : string;
          Filename : string) : integer;
var
  fin : TFileStream;
  size : integer;
  buff : pbyte;
  expires : TTimeStamp;

begin
  result := 200;
  Filename := 'www' + Filename;
  if FileExists(Filename) then
  begin
    expires := DateTimeToTimeStamp(now);
    expires.Date += 30;  // + 30 days

    fin := TFileStream.Create(Filename, fmShareDenyNone);
    size := fin.Size;
    buff := getmemory(fin.Size);
    fin.ReadBuffer(buff^, Size);
    fin.Free;

    try
      ASocket.SendString(
          'HTTP/1.0 200' + CRLF
        + 'Pragma: public' + CRLF
        + 'Cache-Control: max-age=86400' + CRLF
        + 'Expires: ' + Rfc822DateTime(TimeStampToDateTime(expires)) + CRLF
        + 'Content-Type: ' + ContentType + CRLF
        + '' + CRLF);
      ASocket.SendBuffer(buff, size);
    except
      fProgress:='** Error on HTTPServer.SendImage.';
      Synchronize(@DoProgress);
    end;
    freememory(buff);
  end
  else
    result := 404;
end;

// send text file from www directory
// swap @ codes in text files.
function TvtxHTTPServer.SendFile(
          ASocket : TTCPBlockSocket;
          ContentType : string;
          Filename : string) : integer;
var
  fin : TextFile;
  instr, str : string;

begin
  result := 200;
  Filename := 'www' + Filename;
  if FileExists(Filename) then
  begin
    assignfile(fin, Filename);
    reset(fin);
    str := '';
    while not eof(fin) do
    begin
      readln(fin, instr);
      instr := instr.Replace('@UserIP@', ASocket.GetRemoteSinIP);
      instr := instr.Replace('@SystemIP@', SystemInfo.SystemIP);
      instr := instr.Replace('@InternetIP@', SystemInfo.InternetIP);
      instr := instr.Replace('@SystemName@', SystemInfo.SystemName);
      instr := instr.Replace('@HTTPPort@', SystemInfo.HTTPPort);
      instr := instr.Replace('@WSPort@', SystemInfo.WSPort);
      str += instr + CRLF;
    end;
    closefile(fin);

    try
      ASocket.SendString(
          'HTTP/1.0 200' + CRLF
        + 'Content-Type: ' + ContentType + CRLF
        + 'Content-Length: ' + IntToStr(length(str)) + CRLF
        + 'Connection: close' + CRLF
        + 'Date: ' + Rfc822DateTime(now) + CRLF
        + 'Server: VTX Mark-II' + CRLF + CRLF
        + '' + CRLF);
      ASocket.SendString(str);
    except
      fProgress := '** Error on HTTPServer.SendFile';
      Synchronize(@DoProgress);
    end;
  end
  else
    result := 404;
end;

// fulfill the request.
procedure TvtxHTTPServer.AttendConnection(ASocket: TTCPBlockSocket);
var
  timeout,
  code :      integer;
  s,
  ext,
  method,
  uri,
  protocol :  string;

begin
  timeout := 120000;

  //read request line
  s := ASocket.RecvString(timeout);
  method := fetch(s, ' ');
  uri := fetch(s, ' ');
  protocol := fetch(s, ' ');

  //read request headers
  repeat
    s := ASocket.RecvString(Timeout);
  until s = '';

  code := 200;
  if uri = '/' then
    code := SendFile(ASocket, 'text/html', '/index.html')
  else
  begin
    ext := ExtractFileExt(uri);
    case ext of
      '.css':   code := SendFile(ASocket, 'text/css', uri);
      '.js':    code := SendFile(ASocket, 'text/javascript', uri);
      '.png':   code := SendImage(ASocket, 'image/png', uri);
      '.eot':   code := SendImage(ASocket, 'application/vnd.ms-fontobject', uri);
      '.svg':   code := SendImage(ASocket, 'image/svg+xml', uri);
      '.ttf':   code := SendImage(ASocket, 'application/font-sfnt', uri);
      '.woff':  code := SendImage(ASocket, 'application/font-woff', uri);
      '.ogg':   code := SendImage(ASocket, 'audio/ogg', uri);
      '.wav':   code := SendImage(ASocket, 'audio/vnd.wav', uri);
      '.mp3':   code := SendImage(ASocket, 'audio/mpeg', uri);
      // add others here as needed
      else      code := 404;
    end;
  end;

  if code <> 200 then
    ASocket.SendString(
        'HTTP/1.0 ' + IntToStr(code) + CRLF
      + httpCode(code) + CRLF);
end;


{ TvtxProcessNanny }

// thread launched that launches tprocess and waits for it to terminate.
// closes clients connection at end.
constructor TvtxProcessNanny.Create(CreateSuspended: boolean);
begin
  fProgress := '';
  FreeOnTerminate := True;
  inherited Create(CreateSuspended);
end;

destructor TvtxProcessNanny.Destroy;
begin
  // kill the process also
  if (self.serverCon.extProcess <> nil) and self.serverCon.ExtProcess.Running then
  begin
    {$ifdef WINDOWS}
      GenerateConsoleCtrlEvent(CTRL_C_EVENT, serverCon.ExtProcess.ProcessID);
      //serverCon.ExtProcess.Terminate(0);
    {$else}
      FpKill(serverCon.ExtProcess.ProcessID, SIGINT);
    {$endif}
  end;
  inherited Destroy;
end;

procedure TvtxProcessNanny.DoProgress;
begin
  if Assigned(FOnProgress) then
  begin
    FOnProgress('', fProgress);
  end;
end;

procedure TvtxProcessNanny.Execute;
var
  parms : TStringArray;
  i : integer;
begin
  // for each connect that has process, send input, read output
  if serverWS <> nil then
  begin

    fProgress := 'Spawning process for ' + serverCon.Socket.GetRemoteSinIP + '.';
    Synchronize(@DoProgress);

    parms := SystemInfo.ExtProcess.Split(' ');
    for i := 0 to length(parms) - 1 do
    begin
      parms[i] := parms[i].Replace('@UserIP@', self.serverCon.Socket.GetRemoteSinIP);
      parms[i] := parms[i].Replace('@SystemIP@', SystemInfo.SystemIP);
      parms[i] := parms[i].Replace('@InternetIP@', SystemInfo.InternetIP);
      parms[i] := parms[i].Replace('@SystemName@', SystemInfo.SystemName);
      parms[i] := parms[i].Replace('@HTTPPort@', SystemInfo.HTTPPort);
      parms[i] := parms[i].Replace('@WSPort@', SystemInfo.WSPort);
    end;

    self.serverCon.ExtProcess := TProcess.Create(nil);
    self.serverCon.ExtProcess.CurrentDirectory:= 'node';
    self.serverCon.ExtProcess.FreeOnRelease;
    self.serverCon.ExtProcess.Executable := 'node\' + parms[0];
    for i := 1 to length(parms) - 1 do
      serverCon.ExtProcess.Parameters.Add(parms[i]);
    serverCon.ExtProcess.Options := [
        poWaitOnExit,
        poUsePipes,
        poNoConsole,
        poDefaultErrorMode,
        poNewProcessGroup
      ];

    // go run. wait on exit.
    try
      serverCon.ExtProcess.Execute;
    except
      fProgress:='** Error on ProcessNanny.Execute';
      Synchronize(@DoProgress);
    end;
//    serverCon.ExtProcess.Free;

    // diconnect afterwards.
    self.serverCon.Close(wsCloseNormal, 'Good bye');

    fProgress := 'Finished process for '
      + self.serverCon.Socket.GetRemoteSinIP + '.';
    Synchronize(@DoProgress);

  end;
  //fProgress := 'Process Terminating.';
  //Synchronize(@DoProgress);
end;


{ TvtxWSServer }

function TvtxWSServer.GetWebSocketConnectionClass(
          Socket: TTCPCustomConnectionSocket;
          Header: TStringList;
          ResourceName, sHost, sPort, Origin, Cookie: string;
      out HttpResult: integer;
      var Protocol, Extensions: string): TWebSocketServerConnections;
begin
  result := TvtxWSConnection;
end;

{ TvtxApp - main application stuffz }

procedure TvtxApp.HTTPTerminate(Sender : TObject); register;
begin
  WriteCon('', 'HTTP Terminated.');
end;

procedure TvtxApp.BridgeTerminate(Sender: TObject);
begin
  WriteCon('', 'Bridge Terminated.');
end;

procedure TvtxApp.NannyTerminate(Sender: TObject);
begin
  WriteCon('', 'Process Terminated.');
end;

procedure TvtxApp.WSBeforeAddConnection(
      Server :      TCustomServer;
      aConnection : TCustomConnection;
  var CanAdd :      boolean); register;
begin
  WriteCon('', 'Before Add WS Connection.');
end;

procedure TvtxApp.WSAfterAddConnection(
      Server : TCustomServer;
      aConnection : TCustomConnection); register;
var
  con : TvtxWSConnection;
begin
  con := TvtxWSConnection(aConnection);

  WriteCon('', 'WS Connection.');

  con.OnOpen :=  @WSOpen;
  con.OnRead :=  @WSRead;
  con.OnWrite := @WSWrite;
  con.OnClose := @WSClose;

  // spawn a new process for this connection
  con.ExtNanny := TvtxProcessNanny.Create(true);
  con.ExtNanny.serverCon := con;
  con.ExtNanny.OnProgress := @WriteCon;
  con.ExtNanny.OnTerminate := @NannyTerminate;
  try
    con.ExtNanny.Start;
  except
    WriteCon('', '** Error on Nanny Create.');
  end;

end;

procedure TvtxApp.WSOpen(aSender: TWebSocketCustomConnection);
begin
  lastaction := now;
  WriteCon(TvtxWSConnection(aSender).Socket.GetRemoteSinIP, 'Open WS Connection.');
end;

procedure TvtxApp.WSRead(
      aSender : TWebSocketCustomConnection;
      aFinal,
      aRes1,
      aRes2,
      aRes3 :   boolean;
      aCode :   integer;
      aData :   TMemoryStream);
var
  i, bytes : integer;
  str : ansistring;
  con : TvtxWSConnection;
begin
  lastaction := now;
  //WriteCon('Read WS Connection.');

  // send aData to process - doesn't work in bridge so do it here.
  con := TvtxWSConnection(aSender);
  if (con.ExtProcess <> nil) and con.ExtProcess.Running then
  begin
    bytes := aData.Size;
    if bytes > 0 then
    begin
      for i := 0 to bytes - 1 do
      begin
        str += char(aData.ReadByte);
      end;
      try
        con.ExtProcess.Input.WriteAnsiString(str);
      except
        app.WriteCon('', '** Error on sending data to stdin.');
      end;
    end;
  end;
end;

procedure TvtxApp.WSWrite(
      aSender : TWebSocketCustomConnection;
      aFinal,
      aRes1,
      aRes2,
      aRes3 :   boolean;
      aCode :   integer;
      aData :   TMemoryStream);
begin
  lastaction := now;
  //WriteCon('Write WS Connection.');
end;

procedure TvtxApp.WSClose(
      aSender: TWebSocketCustomConnection;
      aCloseCode: integer;
      aCloseReason: string;
      aClosedByPeer: boolean);
begin
  WriteCon(TvtxWSConnection(aSender).Socket.GetRemoteSinIP, 'Close WS Connection.');
end;

procedure TvtxApp.WSBeforeRemoveConnection(
      Server :      TCustomServer;
      aConnection : TCustomConnection); register;
var
  conn : TvtxWSConnection;
begin
  conn := TvtxWSConnection(aConnection);
  if (conn.ExtProcess <> nil) and conn.ExtProcess.Running then
  begin
    WriteCon(TvtxWSConnection(aConnection).Socket.GetRemoteSinIP,
    	'Force Terminate Node Processes');
    try
      conn.ExtProcess.Terminate(0);
    except
      WriteCon('', '** Error terminating node process.');
    end;
  end;
  WriteCon('', 'Before Remove WS Connection.');

end;

procedure TvtxApp.WSAfterRemoveConnection(
      Server : TCustomServer;
      aConnection : TCustomConnection); register;
begin
  WriteCon(aConnection.Socket.GetRemoteSinIP, 'After Remove WS Connection.');
end;

procedure TvtxApp.WSSocketError(
      Server: TCustomServer;
      Socket: TTCPBlockSocket); register;
begin
  WriteCon(Socket.GetRemoteSinIP, 'WS Error : ' + Socket.LastErrorDesc + '.');
end;

procedure TvtxApp.WSTerminate(Sender : TObject); register;
begin
  WriteCon('', 'WS server Terminated.');
end;

procedure TvtxApp.WriteCon(ip, msg : string); register;
var
  ips : array of string;
begin
  write(#13);
  if ip = '' then
	  Write(
			format(#13'%4.2d/%2.2d/%2.2d.%2.2d:%2.2d:%2.2d|               |',
      [
				YearOf(now),		// year
	    	MonthOf(now),		// month
		  	DayOf(now),			// day
				HourOf(now), 		// 24hr
	    	MinuteOf(now),	// min
  	    SecondOf(Now)	// sec
      ]))
  else
  begin
    ips := ip.split('.');
	  Write(
  		format(#13'%4.2d/%2.2d/%2.2d.%2.2d:%2.2d:%2.2d|%3.3d.%3.3d.%3.3d.%3.3d|',
      [
  			YearOf(now),		// year
	    	MonthOf(now),		// month
  	  	DayOf(now),			// day
  			HourOf(now), 		// 24hr
      	MinuteOf(now),	// min
	      SecondOf(Now),	// sec
        strtoint(ips[0]),
        strtoint(ips[1]),
        strtoint(ips[2]),
        strtoint(ips[3])
    	]));
  end;
  writeln(msg);
end;

procedure TvtxApp.StartHTTP;
begin
  // start http server
  if not runningHTTP then
  begin
    WriteCon('', format('HTTP server starting on port %s.', [SystemInfo.HTTPPort]));
    serverHTTP := TvtxHTTPServer.Create(true);
    serverHTTP.OnProgress := @WriteCon;
    serverHTTP.OnTerminate := @HTTPTerminate;
    serverHTTP.Start;
    runningHTTP := true;
  end
  else
    WriteCon('', 'HTTP server already running.');
end;

procedure TvtxApp.StartWS;
begin
  // create websocket server
  if not runningWS then
  begin
    WriteCon('', format('WS server starting on port %s.', [SystemInfo.WSPort]));
    serverWS := TvtxWSServer.Create(SystemInfo.SystemIP, SystemInfo.WSPort);
    serverWS.FreeOnTerminate := true;
    serverWS.MaxConnectionsCount := SystemInfo.MaxConnections;
    serverWS.OnBeforeAddConnection := @WSBeforeAddConnection;
    serverWS.OnAfterAddConnection := @WSAfterAddConnection;
    serverWS.OnBeforeRemoveConnection := @WSBeforeRemoveConnection;
    serverWS.OnAfterRemoveConnection := @WSAfterRemoveConnection;
    serverWS.OnSocketError := @WSSocketError;
    serverWS.OnTerminate := @WSTerminate;
    serverWS.SSL := false;
    serverWS.Start;
    runningWS := true;
  end
  else
    WriteCon('', 'WS server already running.');
end;

procedure TvtxApp.StartBridge;
begin
  // create bridge process to transmit stdin/stdout from client TProcesses
  if not runningBridge then
  begin
    WriteCon('', 'Bridge starting.');
    bridgeWS := TvtxIOBridge.Create(true);
    bridgeWS.OnProgress := @WriteCon;
    bridgeWS.OnTerminate := @BridgeTerminate;
    bridgeWS.Start;
    runningBridge := true;
  end
  else
    WriteCon('', 'Bridge is already running.');
end;

procedure TvtxApp.StopHTTP;
begin
  if runningHTTP then
  begin
    WriteCon('', 'HTTP server terminating.');
    if serverHTTP <> nil then
      serverHTTP.Terminate;
    runningHTTP := false;
  end;
end;

{ Call CloseAllConnections prior to calling. }
procedure TvtxApp.StopWS;
var
  i : integer;
  conn : TvtxWSConnection;

begin
  if runningWS then
  begin
    WriteCon('', 'WS server terminating.');
    if serverWS <> nil then
      serverWS.Terminate;
    runningWS := false;
  end;
end;

procedure TvtxApp.StopBridge;
begin
  if runningBridge then
  begin
    WriteCon('', 'Bridge server terminating.');
    if bridgeWS <> nil then
      bridgeWS.Terminate;
    runningBridge := false;
  end;
end;

{ Terminate all end all client node processes, close all connections }
procedure TvtxApp.CloseAllNodes;
var
  i : integer;
begin
  // terminate all node processes.
  if runningWS then
  begin
    i := serverWS.Count - 1;
    while i >= 0 do
    begin
      CloseNode(i);
      dec(i);
    end;
  end;
end;

procedure TvtxApp.CloseNode(n : integer);
var
  con : TvtxWSConnection;
begin
  if not serverWS.Connection[n].Finished then
  begin
    con := TvtxWSConnection(serverWS.Connection[n]);
    if con.ExtProcess.Running then
      try
        con.ExtProcess.Terminate(1);
      finally
        WriteCon('', 'Node Process terminated.');
      end;
  end;
end;

{ read the vtxserv.ini file for settings }
procedure LoadSettings;
var
  iin : TIniFile;

const
  sect = 'Config';

begin
  iin := TIniFile.Create('vtxserv.ini');
  SystemInfo.SystemName :=  iin.ReadString(sect, 'SystmeName',  'A VTX Board');
  SystemInfo.SystemIP :=    iin.ReadString(sect, 'SystemIP',    'localhost');
  SystemInfo.InternetIP :=  iin.ReadString(sect, 'InternetIP',  '142.105.247.156');
  SystemInfo.HTTPPort :=    iin.ReadString(sect, 'HTTPPort',    '7001');
  SystemInfo.WSPort :=      iin.ReadString(sect, 'WSPort',      '7003');
  SystemInfo.ExtProcess :=  iin.ReadString(sect, 'ExtProcess',  'cscript.exe //Nologo //I test.js @UserIP@');
  SystemInfo.MaxConnections := iin.ReadInteger(sect, 'MaxConnections',  32);
  iin.Free;
end;

{ the bla bla on a socket error. }
function GetSocketErrorMsg(errno : integer) : string;
begin
  result := 'Unknown error.';
  case errno of
    6:  result := 'Specified event object handle is invalid.';
    8:  result := 'Insufficient memory available.';
    87: result := 'One or more parameters are invalid.';
    995:  result := 'Overlapped operation aborted.';
    996:  result := 'Overlapped I/O event object not in signaled state.';
    997:  result := 'Overlapped operations will complete later.';
    10004:  result := 'Interrupted function call.';
    10009:  result := 'File handle is not valid.';
    10013:  result := 'Permission denied.';
    10014:  result := 'Bad address.';
    10022:  result := 'Invalid argument.';
    10024:  result := 'Too many open files.';
    10035:  result := 'Resource temporarily unavailable.';
    10036:  result := 'Operation now in progress.';
    10037:  result := 'Operation already in progress.';
    10038:  result := 'Socket operation on nonsocket.';
    10039:  result := 'Destination address required.';
    10040:  result := 'Message too long.';
    10041:  result := 'Protocol wrong type for socket.';
    10042:  result := 'Bad protocol option.';
    10043:  result := 'Protocol not supported.';
    10044:  result := 'Socket type not supported.';
    10045:  result := 'Operation not supported.';
    10046:  result := 'Protocol family not supported.';
    10047:  result := 'Address family not supported by protocol family.';
    10048:  result := 'Address already in use.';
    10049:  result := 'Cannot assign requested address.';
    10050:  result := 'Network is down.';
    10051:  result := 'Network is unreachable.';
    10052:  result := 'Network dropped connection on reset.';
    10053:  result := 'Software caused connection abort.';
    10054:  result := 'Connection reset by peer.';
    10055:  result := 'No buffer space available.';
    10056:  result := 'Socket is already connected.';
    10057:  result := 'Socket is not connected.';
    10058:  result := 'Cannot send after socket shutdown.';
    10059:  result := 'Too many references.';
    10060:  result := 'Connection timed out.';
    10061:  result := 'Connection refused.';
    10062:  result := 'Cannot translate name.';
    10063:  result := 'Name too long.';
    10064:  result := 'Host is down.';
    10065:  result := 'No route to host.';
    10066:  result := 'Directory not empty.';
    10067:  result := 'Too many processes.';
    10068:  result := 'User quota exceeded.';
    10069:  result := 'Disk quota exceeded.';
    10070:  result := 'Stale file handle reference.';
    10071:  result := 'Item is remote.';
    10091:  result := 'Network subsystem is unavailable.';
    10092:  result := 'Winsock.dll version out of range.';
    10093:  result := 'Successful WSAStartup not yet performed.';
    10101:  result := 'Graceful shutdown in progress.';
    10102:  result := 'No more results.';
    10103:  result := 'Call has been canceled.';
    10104:  result := 'Procedure call table is invalid.';
    10105:  result := 'Service provider is invalid.';
    10106:  result := 'Service provider failed to initialize.';
    10107:  result := 'System call failure.';
    10108:  result := 'Service not found.';
    10109:  result := 'Class type not found.';
    10110:  result := 'No more results.';
    10111:  result := 'Call was canceled.';
    10112:  result := 'Database query was refused.';
    11001:  result := 'Host not found.';
    11002:  result := 'Nonauthoritative host not found.';
    11003:  result := 'This is a nonrecoverable error.';
    11004:  result := 'Valid name, no data record of requested type.';
    11005:  result := 'QoS receivers.';
    11006:  result := 'QoS senders.';
    11007:  result := 'No QoS senders.';
    11008:  result := 'QoS no receivers.';
    11009:  result := 'QoS request confirmed.';
    11010:  result := 'QoS admission error.';
    11011:  result := 'QoS policy failure.';
    11012:  result := 'QoS bad style.';
    11013:  result := 'QoS bad object.';
    11014:  result := 'QoS traffic control error.';
    11015:  result := 'QoS generic error.';
    11016:  result := 'QoS service type error.';
    11017:  result := 'QoS flowspec error.';
    11018:  result := 'Invalid QoS provider buffer.';
    11019:  result := 'Invalid QoS filter style.';
    11020:  result := 'Invalid QoS filter type.';
    11021:  result := 'Incorrect QoS filter count.';
    11022:  result := 'Invalid QoS object length.';
    11023:  result := 'Incorrect QoS flow count.';
    11024:  result := 'Unrecognized QoS object.';
    11025:  result := 'Invalid QoS policy object.';
    11026:  result := 'Invalid QoS flow descriptor.';
    11027:  result := 'Invalid QoS provider-specific flowspec.';
    11028:  result := 'Invalid QoS provider-specific filterspec.';
    11029:  result := 'Invalid QoS shape discard mode object.';
    11030:  result := 'Invalid QoS shaping rate object.';
    11031:  result := 'Reserved policy QoS element type.';
  end
end;

{ get services associated with words in list 1 .. end }
function GetServFromWords(word : TStringArray) : TServSet;
var
  i : integer;

begin
  result := [];
  for i := 1 to Length(word) - 1 do
  begin
    case upcase(word[i]) of
      'HTTP':   result += [ HTTP ];
      'WS':     result += [ WS ];
      'BRIDGE': result += [ Bridge ];
      'ALL' :   result += [ All ];
      else      result += [ Unknown ];
    end;
  end;
end;

{ read a console line, returns '' if none entered }
var
  cmdbuff :   string = '';      // console linein buffer

function ConsoleLineIn : string;
var
  key :     char;

begin
  result := '';
  if wherex = 1 then
    write(']' + cmdbuff);
  if keypressed then
  begin
    lastaction := now;
    key := readkey;
    if key <> #0 then
    begin
      case key of
        #13:
          begin
            write(CRLF);
            result := cmdbuff;
            cmdbuff := '';
          end;

        #8: // backspace
          begin
            if length(cmdbuff) > 0 then
            begin
              write(#8' '#8);
              cmdbuff := LeftStr(cmdbuff, cmdbuff.length - 1);
            end;
          end;
        else
          begin
            write(key);
            cmdbuff += key;
          end;
      end;
    end
    else
    begin
      // special key
      key := readkey;
      case ord(key) of
        $4B:  // left arrow
          begin
            if length(cmdbuff) > 0 then
            begin
              write(#8' '#8);
              cmdbuff := LeftStr(cmdbuff, cmdbuff.length - 1);
            end;
          end;
        else  beep;
      end;
    end;
  end;
end;

{$R *.res}

var
  linein :      string;
  word :        TStringArray;
  serv :        TServSet;
  Done :        boolean;
  Hybernate :   boolean;
  Found :       boolean;
  i :           integer;
  cp :          TCodePages;
  str :         string;
  fout :        TextFile;
  count : integer;
  ThreadRan : boolean;

begin

  {$IFDEF WINDOWS}
    SetConsoleOutputCP(CP_UTF8);
  {$ENDIF}

  write('VTX Server Console.' + CRLF
      + '2017 Dan Mecklenburg Jr.' + CRLF
      + CRLF
      + 'Type HELP for commands, QUIT to exit.' + CRLF + CRLF);

  app :=            TvtxApp.Create;
  serverWS :=       nil;
  runningHTTP :=    false;
  runningWS :=      false;
  runningBridge :=  false;
  Done :=           false;
  Hybernate :=      false;

  LoadSettings;

  lastaction := now;

  linein := '';
  repeat
    linein := ConsoleLineIn;
    if linein <> '' then
    begin
      // parse command
        word := linein.Split(' ');
        case upcase(word[0]) of
        'START':  // start a servive.
            begin
              serv := GetServFromWords(word);
              if Unknown in serv then
                app.WriteCon('', 'Unknown service specified.')
              else if serv = [] then
                app.WriteCon('', 'No service specified.')
              else
              begin
                if All in serv then
                begin
                  app.StartHTTP;
                  app.StartWS;
                  app.StartBridge;
                end
                else
                begin
                  if HTTP in serv then
                    app.StartHTTP;
                  if WS in serv then
                    app.StartWS;
                  if Bridge in serv then
                    app.StartBridge;
                end;
              end;
            end;

        'STOP': // stop a service.
            begin
              serv := GetServFromWords(word);
              if Unknown in serv then
                app.WriteCon('', 'Unknown service specified.')
              else if serv = [] then
                app.WriteCon('', 'No service specified.')
              else
              begin
                if All in serv then
                begin
                  app.StopHTTP;
                  app.CloseAllNodes();
                  app.StopWS;
                  app.StopBridge;
                end
                else
                begin
                  if HTTP in serv then
                    app.StopHTTP;
                  if WS in serv then
                  begin
                    app.CloseAllNodes();
                    app.StopWS;
                  end;
                  if Bridge in serv then
                    app.StopBridge;
                end;
              end;
            end;

        'STATUS':
          begin
            linein := '';
            if runningHTTP    then linein += 'HTTP, ';
            if runningWS      then linein += 'WS, ';
            if runningBridge  then linein += 'Bridge, ';
            if linein = ''    then linein += 'None, ';
            linein := LeftStr(linein, linein.length - 2);
            app.WriteCon('', 'Currently running services: ' + linein);
            if runningWS then
             app.WriteCon('', 'Current WS connections: ' + inttostr(serverWS.Count));
          end;

        'QUIT':   Done := true;

        'CLS':    ClrScr;

        'LIST':   // list connection
          begin
            if runningWS then
            begin
              count := 0;
              for i := 0 to serverWS.Count - 1 do
              begin
                if not serverWS.Connection[i].IsTerminated then
                begin
                  app.WriteCon('', format('%d) %s', [
                    i + 1,
                    serverWS.Connection[i].Socket.GetRemoteSinIP ]));
                  inc(count);
                end;
              end;
              if count = 0 then
                app.WriteCon('', 'No active connections.');
            end
            else
              app.WriteCon('', 'WS service is not running.');
          end;

        'KICK':   // kick a connection
          begin
            if runningWS then
            begin
              if length(word) = 2 then
              begin
                i := strtoint(word[1]) - 1;
                if (i >= 0) and (i < serverWS.Count) then
                begin
                  if not serverWS.Connection[i].IsTerminated then
                  begin
                    app.CloseNode(i);
                  end
                  else
                  begin
                    app.WriteCon('', 'Connection already closed..');
                  end;
                end
                else
                  app.WriteCon('', 'No such connection.');
              end
              else
                app.WriteCon('', 'Specify a connection number. (See LIST)');
            end
            else
              app.WriteCon('', 'WS service is not running.');
          end;

        'CONV':
          begin
            if length(word) = 4 then
            begin
              Found := false;
              for cp := FirstCP to LastCP do
              begin
                if CodePageNames[cp] = upcase(word[1]) then
                begin
                  if fileexists(word[2]) then
                  begin
                    str := Convert(cp, word[2]);
                    assign(fout, word[3]);
                    rewrite(fout);
                    write(fout, str);
                    closefile(fout);
                    app.WriteCon('', 'Saved.');
                    Found := true;
                  end
                  else
                  begin
                    app.WriteCon('', 'Unable to locate input file.');
                    Found := true;
                  end;
                  break;
                end;
              end;
              if not Found then
                app.WriteCon('', 'Unsupported Codepage. See CPS.');
            end
            else
              app.WriteCon('', 'Invalid number of parameters.');
          end;

        'CPS':
          begin
            str := 'Supported codepages : ';
            for cp := FirstCP to LastCP do
              str += CodePageNames[cp] + ', ';
            str := LeftStr(str, length(str) - 2) + '.';
            app.WriteCon('', str);
          end;

        'HELP':
          begin
            app.WriteCon('', 'Commands: START <serv> [<serv> ..]  - Start one or more service.');
            app.WriteCon('', '          STOP <serv> [<serv> ..]  - Stop one or more service.');
            app.WriteCon('', '          STATUS  - Display what''s running.');
            app.WriteCon('', '          LIST  - List current WS connections.');
            app.WriteCon('', '          KICK <connum>  - Disconnect a WS connection.');
            app.WriteCon('', '          CLS  - Clear console screen.');
            app.WriteCon('', '          HELP  - You''re soaking in it.');
            app.WriteCon('', '          QUIT  - Stop all services and exit.');
            app.WriteCon('', '          CONV <codepage> <input> <output>  - Convert text file to UTF8.');
            app.WriteCon('', '          CPS  - List supported codepages available for CONV.');
            app.WriteCon('', '');
            app.WriteCon('', '          serv = HTTP, WS, Bridge, or ALL');
          end
          else
          	app.WriteCon('', 'Unknown command.');
      end;
    end;

    // tickle the threads.
    ThreadRan := CheckSynchronize;
    if ThreadRan then
    begin
      app.WriteCon('', 'A thread ran.');
    end;

    // hybernate mode?
    if SecondsBetween(now, lastaction) > 120 then
    begin
      if not Hybernate then
        app.WriteCon('', 'Hybernating.... zzz...');

      Hybernate := true;
      sleep(100);
    end
    else
    begin
      if Hybernate then
        app.WriteCon('', 'Waking up! O.O');

      Hybernate := false;
    end;

  until Done;

  app.CloseAllNodes;
  app.StopHTTP;
  app.StopWS;
  app.StopBridge;
  sleep(2000);
end.
