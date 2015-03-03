{
  Copyright 2015-2015 Michalis Kamburelis.

  This file is part of "Hydra Battles".

  "Hydra Battles" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Hydra Battles" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{$modeswitch nestedprocvars}{$H+}

{ Game state to play actual game. }
unit GameStatePlay;

interface

uses Classes, FGL,
  CastleConfig, CastleKeysMouse, CastleControls, Castle2DSceneManager,
  CastleColors, CastleUIControls,
  GameStates, GameMap, GameNpcs, GamePath, GameProps, GameUtils,
  GamePlayerSidebar;

type
  { Currently drawn paths with mouse / touch device. Support multi-touch
    (crucial for our game to enable 2 players simultaneously drawing paths)
    by supporting multiple paths, for different finger index. }
  TCurrentPaths = specialize TFPGMap<TFingerIndex, TPath>;

  TCurrentDraggedProps = specialize TFPGMap<TFingerIndex, TDraggedProp>;

  TStatePlay = class(TState)
  private
  type
    TFadeControl = class(TUIControl)
    public
      Color: TCastleColor;
      procedure Render; override;
    end;
  var
    Status: TCastleLabel;
    Props: TProps;
    Map: TMap;
    MapBackground: TMapBackground;
    Npcs: TNpcs;
    CurrentPaths: TCurrentPaths;
    CurrentDraggedProps: TCurrentDraggedProps;
    Sidebar: array [TFaction] of TPlayerSidebar;
    GameOver: boolean;
    GameOverButton: TCastleButton;
    GameOverColor: TCastleColor;
    FadeControl: TFadeControl;
    function NpcFromPath(const Path: TPath): TNpcInstance;
    procedure GameOverClick(Sender: TObject);
  public
    StartMapName: string;
    constructor Create(AOwner: TComponent); override;
    procedure Start; override;
    procedure Finish; override;
    procedure Resize; override;
    procedure Update(const SecondsPassed: Single); override;
    procedure Press(const Event: TInputPressRelease); override;
    procedure Release(const Event: TInputPressRelease); override;
    procedure Motion(const Event: TInputMotion); override;
    procedure GLContextOpen; override;
    procedure GLContextClose; override;
  end;

var
  StatePlay: TStatePlay;

implementation

uses SysUtils,
  CastleScene, CastleVectors, CastleFilesUtils, CastleSceneCore,
  CastleUtils, CastleGLUtils,
  CastleGLImages, CastleStringUtils, CastleRectangles, CastleGameNotifications,
  GameStateMainMenu, GameAbstractMap;

{ TFadeControl --------------------------------------------------------------- }

procedure TStatePlay.TFadeControl.Render;
begin
  inherited;
  GLFadeRectangle(Container.Rect, Color, 1);
end;

{ TStatePlay ----------------------------------------------------------------- }

constructor TStatePlay.Create(AOwner: TComponent);
begin
  inherited;
end;

procedure TStatePlay.Start;
var
  FT: TFaction;
begin
  inherited;

  GameTime := 0;

  CurrentPaths := TCurrentPaths.Create;
  CurrentDraggedProps := TCurrentDraggedProps.Create;

  Props := TProps.Create;
  Npcs := TNpcs.Create;

  MapBackground := TMapBackground.Create(StartMapName);
  Window.Controls.InsertFront(MapBackground);

  VisualizationSceneManager := T2DSceneManager.Create(Self);
  VisualizationSceneManager.FullSize :=false;
  VisualizationSceneManager.Transparent := true;
  Window.Controls.InsertFront(VisualizationSceneManager);

  Map := TMap.Create(StartMapName, Props, Npcs);
  Window.Controls.InsertFront(Map);

  Status := TCastleLabel.Create(Self);
  Status.Padding := 5;
  Status.Color := White;
  Status.Left := 10;
  Status.Bottom := 10;
  Status.Frame := false;
  Status.Alignment := prRight;
  Window.Controls.InsertFront(Status);

  for FT := Low(FT) to High(FT) do
  begin
    Sidebar[FT] := TPlayerSidebar.Create(Self, FT, Props);
    Window.Controls.InsertFront(Sidebar[FT]);

    Wood[FT] := Map.InitialWood;
  end;

  Window.Controls.InsertFront(Notifications);

  FactionExclusiveMoves := GameConf.GetValue('faction_exclusive_moves', false);
  FactionExclusiveMovesDuration := GameConf.GetValue('faction_exclusive_moves_duration', 1);

  GameOver := false;
end;

procedure TStatePlay.Finish;
var
  FT: TFaction;
  I: Integer;
begin
  FreeAndNil(Status);
  FreeAndNil(VisualizationSceneManager);
  FreeAndNil(Map);
  FreeAndNil(MapBackground);
  FreeAndNil(Props);
  FreeAndNil(Npcs);
  FreeAndNil(CurrentPaths);
  if CurrentDraggedProps <> nil then
  begin
    for I := 0 to CurrentDraggedProps.Count - 1 do
    begin
      CurrentDraggedProps.Data[I].Free;
      CurrentDraggedProps.Data[I] := nil;
    end;
    FreeAndNil(CurrentDraggedProps);
  end;
  for FT := Low(FT) to High(FT) do
    FreeAndNil(Sidebar[FT]);
  Window.Controls.Remove(Notifications);
  FreeAndNil(GameOverButton);
  FreeAndNil(FadeControl);
  inherited;
end;

procedure TStatePlay.Resize;
var
  R, GameOverButtonRect: TRectangle;
begin
  inherited;

  R := Map.Rect;
  MapBackground.Rect := R;
  VisualizationSceneManager.Left := R.Left;
  VisualizationSceneManager.Bottom := R.Bottom;
  VisualizationSceneManager.Width := R.Width;
  VisualizationSceneManager.Height := R.Height;

  Sidebar[ftHumans].Left := R.Left - PlayerSidebarWidth;
  Sidebar[ftHumans].Bottom := R.Bottom;
  Sidebar[ftHumans].Height := R.Height;

  Sidebar[ftMonsters].Left := R.Right;
  Sidebar[ftMonsters].Bottom := R.Bottom;
  Sidebar[ftMonsters].Height := R.Height;

  if GameOverButton <> nil then
  begin
    GameOverButtonRect := R.Grow(-R.Width div 4, -R.Height div 4);
    GameOverButton.Left := GameOverButtonRect.Left;
    GameOverButton.Bottom := GameOverButtonRect.Bottom;
    GameOverButton.Width := GameOverButtonRect.Width;
    GameOverButton.Height := GameOverButtonRect.Height;
  end;
end;

procedure TStatePlay.Update(const SecondsPassed: Single);

  function GameLost(const F: TFaction): boolean;
  var
    I: Integer;
  begin
    for I := 0 to Map.NpcInstances.Count - 1 do
      if Map.NpcInstances[I].Npc.Faction = F then
        Exit(false);

    for I := 0 to Map.PropInstances.Count - 1 do
      if (not Map.PropInstances[I].Prop.Neutral) and
         (Map.PropInstances[I].Prop.Faction = F) then
        Exit(false);

    if Trunc(Wood[F]) > Props[Headquarters[F]].CostWood then
      Exit(false);

    { no npcs, no buildings, no money to build hq -> lost }
    Result := true;
  end;

var
  S, GameOverMessage: string;
  HumansLost, MonstersLost: boolean;
begin
  inherited;

  S := Format('FPS: %f real : %f', [Window.Fps.FrameTime, Window.Fps.RealTime]);
  Status.Text.Text := S;
  Status.AlignHorizontal(prRight, prRight);
  Status.AlignVertical(prTop, prTop);

  GameTime += SecondsPassed;

  if not GameOver then
  begin
    HumansLost := GameLost(ftHumans);
    MonstersLost := GameLost(ftMonsters);
    if HumansLost and not MonstersLost then
    begin
      GameOver := true;
      GameOverMessage := 'Humans Lost!';
      GameOverColor := Red;
    end else
    if (not HumansLost) and MonstersLost then
    begin
      GameOver := true;
      GameOverMessage := 'Monsters Lost!';
      GameOverColor := Blue;
    end else
    if HumansLost and MonstersLost then
    begin
      GameOver := true;
      GameOverMessage := 'Both factions lost, draw!';
      GameOverColor := Gray;
    end;
    if GameOver then
    begin
      FadeControl := TFadeControl.Create(Self);
      FadeControl.Color := GameOverColor;
      Window.Controls.InsertFront(FadeControl);

      GameOverButton := TCastleButton.Create(Self);
      GameOverButton.AutoSize := false;
      GameOverButton.OnClick := @GameOverClick;
      GameOverButton.Caption := GameOverMessage;
      Window.Controls.InsertFront(GameOverButton);

      Resize; // set GameOverButton sizes
    end;
  end;

  Window.Invalidate;
end;

procedure TStatePlay.Press(const Event: TInputPressRelease);

  function TryNpcDragging(const PathStartX, PathStartY: Integer): boolean;
  var
    NewPath: TPath;
    Npc: TNpcInstance;
  begin
    Result :=
      Map.ValidCoord(PathStartX, PathStartY) and
      (Map.MapNpcs[PathStartX, PathStartY] <> nil) and
      FactionCanMove((Map.MapNpcs[PathStartX, PathStartY].Npc.Faction));
    if Result then
    begin
      Npc := Map.MapNpcs[PathStartX, PathStartY];
      NewPath := TPath.Create(Map, PathStartX, PathStartY, Npc.Npc.Faction);
      CurrentPaths[Event.FingerIndex] := NewPath;
      Npc.Path := NewPath;
    end;
  end;

  procedure TryNpcDraggingNeighbor(const PathStartX, PathStartY: Integer;
    var ContinueToNeighbors: boolean);
  begin
    if TryNpcDragging(PathStartX, PathStartY) then
      ContinueToNeighbors := false;
  end;

  function TryDraggingSidebar: boolean;
  var
    I: Integer;
    FT: TFaction;
    DraggingPropType: TProp;
    DragProp: TDraggedProp;
  begin
    Result := false;

    for FT := Low(FT) to High(FT) do
      if Sidebar[FT].StartsDragging(Map.PropInstances, Event.Position,
        DraggingPropType) then
      begin
        Result := true;

        I := CurrentDraggedProps.IndexOf(Event.FingerIndex);
        if I <> -1 then
        begin
          DragProp := CurrentDraggedProps.Data[I];
          FreeAndNil(DragProp);
          CurrentDraggedProps.Delete(I);
        end;

        if DraggingPropType.Neutral or
           FactionCanMove(DraggingPropType.Faction) then
        begin
          DragProp := TDraggedProp.Create(Self);
          DragProp.Map := Map;
          DragProp.Prop := DraggingPropType;
          Window.Controls.InsertFront(DragProp);
          CurrentDraggedProps[Event.FingerIndex] := DragProp;
        end;
      end;
  end;

var
  PT: TPropType;
  Prop: TProp;
  RandomMountain: char;
  MouseTileX, MouseTileY: Integer;
begin
  inherited;

  if Event.IsKey('E') then
    Map.EditMode := not Map.EditMode;
  if Event.IsKey('G') then
    Map.Grid := not Map.Grid;

  if Map.EditMode then
  begin
    if Event.IsKey(K_Up) then
      Map.EditCursor[1] := Map.EditCursor[1] + 1;
    if Event.IsKey(K_Down) then
      Map.EditCursor[1] := Map.EditCursor[1] - 1;
    if Event.IsKey(K_Right) then
      Map.EditCursor[0] := Map.EditCursor[0] + 1;
    if Event.IsKey(K_Left) then
      Map.EditCursor[0] := Map.EditCursor[0] - 1;
    Map.EditCursor[0] := Clamped(Map.EditCursor[0], 0, Map.Width - 1);
    Map.EditCursor[1] := Clamped(Map.EditCursor[1], 0, Map.Height - 1);
    for PT := Low(PT) to High(PT) do
    begin
      Prop := Props[PT];
      if Event.IsKey(Prop.EditorShortcut) then
        Map.SetPropInstance(Map.EditCursor[0], Map.EditCursor[1], TPropInstance.Create(Prop));
    end;
    if Event.IsKey('0') then
    begin
      RandomMountain := Chr(Random(8) + Ord('1'));
      for PT := Low(PT) to High(PT) do
      begin
        Prop := Props[PT];
        if Prop.EditorShortcut = RandomMountain then
          Map.SetPropInstance(Map.EditCursor[0], Map.EditCursor[1], TPropInstance.Create(Prop));
      end;
    end;
    if Event.IsKey(' ') then
      Map.SetPropInstance(Map.EditCursor[0], Map.EditCursor[1], nil);
    if Event.IsKey('S') then
      Map.SaveToFile;
    if Event.IsKey('N') then
    begin
      Map.SetNpcInstance(Map.EditCursor[0], Map.EditCursor[1],
        TNpcInstance.Create(Npcs.Npcs[RandomFaction, RandomNpcType], RandomDirection));
    end;
  end;

  if Event.IsMouseButton(mbLeft) then
  begin
    if TryDraggingSidebar then
      Exit;

    if Map.PositionToTile(Map.Rect, Event.Position, MouseTileX, MouseTileY) then
    begin
      if TryNpcDragging(MouseTileX, MouseTileY) then
        Exit;

      if Map.MapProps[MouseTileX, MouseTileY] <> nil then
      begin
        Map.MapProps[MouseTileX, MouseTileY].StartTraining(Npcs);
        Exit;
      end;

      HandleNeighbors(MouseTileX, MouseTileY, @TryNpcDraggingNeighbor);
    end;
  end;
end;

procedure TStatePlay.Release(const Event: TInputPressRelease);

  procedure TryDraggingSidebar;
  var
    I: Integer;
    DragProp: TDraggedProp;
  begin
    I := CurrentDraggedProps.IndexOf(Event.FingerIndex);
    if I <> -1 then
    begin
      DragProp := CurrentDraggedProps.Data[I];

      { update DragProp.X, Y for the last time }
      if not Map.PositionToTile(Map.Rect, Event.Position, DragProp.X, DragProp.Y) then
      begin
        DragProp.X := -1;
        DragProp.Y := -1;
      end;

      if (DragProp.X <> -1) and
         (DragProp.Y <> -1) then
      begin
        if DragProp.Prop.CanBuild(Map.PropInstances) then
        begin
          if Map.ValidTile(DragProp.X, DragProp.Y, nil) then
          begin
            Wood[DragProp.Prop.Faction] -= DragProp.Prop.CostWood;
            Map.SetPropInstance(DragProp.X, DragProp.Y, TPropInstance.Create(DragProp.Prop));
          end else
            Notifications.Show(Format('Cannot build "%s" at this place (blocked)',
              [DragProp.Prop.Caption]));
        end;
      end;

      DragProp.Free;
      CurrentDraggedProps.Delete(I);
    end;
  end;

begin
  inherited;
  if Event.IsMouseButton(mbLeft) then
  begin
    CurrentPaths.Remove(Event.FingerIndex);
    TryDraggingSidebar;
  end;
end;

function TStatePlay.NpcFromPath(const Path: TPath): TNpcInstance;
var
  I: Integer;
begin
  for I := 0 to Map.NpcInstances.Count - 1 do
    if Map.NpcInstances[I].Path = Path then
      Exit(Map.NpcInstances[I]);
  Exit(nil);
end;

procedure TStatePlay.Motion(const Event: TInputMotion);

  procedure TryDraggingSidebar;
  var
    I: Integer;
    DragProp: TDraggedProp;
  begin
    I := CurrentDraggedProps.IndexOf(Event.FingerIndex);
    if I <> -1 then
    begin
      DragProp := CurrentDraggedProps.Data[I];
      { update DragProp.ScreenPosition, X, Y }
      DragProp.ScreenPosition := Event.Position;
      if not Map.PositionToTile(Map.Rect, Event.Position, DragProp.X, DragProp.Y) then
      begin
        DragProp.X := -1;
        DragProp.Y := -1;
      end;
    end;
  end;

var
  X, Y, PathUnderFingerIndex: Integer;
  MapRect: TRectangle;
  CurrentPath: TPath;
  PathNpc: TNpcInstance;
begin
  inherited;

  PathUnderFingerIndex := CurrentPaths.IndexOf(Event.FingerIndex);
  if PathUnderFingerIndex <> -1 then
  begin
    CurrentPath := CurrentPaths.Data[PathUnderFingerIndex];
    PathNpc := NpcFromPath(CurrentPath);
    if PathNpc = nil then
      { TODO: ugly to detect it like this.
        This means that Path was already freed in TNpcInstance,
        and CurrentPaths contains reference to invalid object. }
      CurrentPaths.Remove(Event.FingerIndex) else
    begin
      MapRect := Map.Rect;
      if Map.PositionToTile(MapRect, Event.Position, X, Y) then
      begin
        Map.EditCursor[0] := X;
        Map.EditCursor[1] := Y;
        CurrentPath.Add(X, Y);
      end;
    end;
  end;

  TryDraggingSidebar;
end;

procedure TStatePlay.GLContextOpen;
begin
  inherited;
  Props.GLContextOpen;
  Npcs.GLContextOpen;
end;

procedure TStatePlay.GLContextClose;
begin
  if Props <> nil then
    Props.GLContextClose;
  if Npcs <> nil then
    Npcs.GLContextClose;
  inherited;
end;

procedure TStatePlay.GameOverClick(Sender: TObject);
begin
  TState.Current := StateMainMenu;
end;

end.
