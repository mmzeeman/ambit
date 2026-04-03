#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa _build/default/lib/hexveil/ebin

main([LatStr, LonStr, LevelStr, RadiusStr]) ->
    Lat = list_to_float(LatStr),
    Lon = list_to_float(LonStr),
    Level = list_to_integer(LevelStr),
    Radius = list_to_integer(RadiusStr),
    generate_svg(Lat, Lon, Level, Radius);
main([LatStr, LonStr, LevelStr]) ->
    main([LatStr, LonStr, LevelStr, "3"]);
main(_) ->
    io:format("Usage: ./hexveil_svg <lat> <lon> <level> [radius]~n"),
    io:format("Example: ./hexveil_svg 52.3616 4.8784 17 5~n").

generate_svg(Lat, Lon, Level, Radius) ->
    Levels = [Level, Level-1, Level-2],
    {Q24, R24} = hexveil:encode(Lat, Lon),
    
    Shift0 = 24 - Level,
    QC0 = Q24 bsr Shift0,
    RC0 = R24 bsr Shift0,
    FineHexes = [ {Q, R} || Q <- lists:seq(QC0 - Radius, QC0 + Radius),
                            R <- lists:seq(RC0 - Radius, RC0 + Radius),
                            hex_dist({Q, R}, {QC0, RC0}) =< Radius ],

    Project = fun({PLat, PLon}) ->
        {X, Y} = latlon_to_xy_local(PLat, PLon, Lat, Lon),
        {X, -Y}
    end,

    %% Project all unique hexes at all requested levels
    XYPolygonsByLevel = [begin
        Shift = 24 - L,
        L_Shift = Level - L,
        UniqueHexes = lists:usort([ {Q bsr L_Shift, R bsr L_Shift} || {Q, R} <- FineHexes ]),
        [ begin
            Corners = hexveil:cell_geometry({Q bsl Shift, R bsl Shift}, L),
            Code = hexveil:display({Q bsl Shift, R bsl Shift}, L),
            {CLat, CLon} = hexveil:decode({Q bsl Shift, R bsl Shift}, L),
            CenterXY = Project({CLat, CLon}),
            
            %% Scale parent levels by 1.2 to "surround" children and overlap
            Scale = if L == Level -> 1.0; true -> 1.2 end,
            XYCorners = [begin 
                            {CX, CY} = Project(C),
                            {Center_X, Center_Y} = CenterXY,
                            {Center_X + (CX - Center_X) * Scale, Center_Y + (CY - Center_Y) * Scale}
                         end || C <- Corners],

            {Q, R, Code, L, XYCorners, CenterXY}
          end || {Q, R} <- UniqueHexes ]
    end || L <- Levels],

    Flattened = lists:flatten(XYPolygonsByLevel),
    AllX = [X || {_, _, _, _, P, {CX, _}} <- Flattened, {X, _} <- [CX|P]],
    AllY = [Y || {_, _, _, _, P, {_, CY}} <- Flattened, {_, Y} <- [CY|P]],
    
    MinX = lists:min(AllX), MaxX = lists:max(AllX),
    MinY = lists:min(AllY), MaxY = lists:max(AllY),
    
    Padding = 150,
    Width = MaxX - MinX + Padding * 2,
    Height = MaxY - MinY + Padding * 2,
    OffX = -MinX + Padding,
    OffY = -MinY + Padding,

    {IX, IY} = Project({Lat, Lon}),
    PX = IX + OffX,
    PY = IY + OffY,

    SVG = [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
        io_lib:format("<svg width=\"~f\" height=\"~f\" xmlns=\"http://www.w3.org/2000/svg\">\n", [Width, Height]),
        "<rect width=\"100%\" height=\"100%\" fill=\"#f8f9fa\" />\n",
        
        io_lib:format("<text x=\"20\" y=\"30\" font-family=\"sans-serif\" font-size=\"16\" font-weight=\"bold\" fill=\"#212529\">HexVeil Overlapping Hierarchy</text>\n", []),
        io_lib:format("<text x=\"20\" y=\"55\" font-family=\"sans-serif\" font-size=\"12\" fill=\"#495057\">Center: ~f, ~f | Levels: ~w</text>\n", [Lat, Lon, Levels]),

        %% 1. Draw Fine Polygons with TINT based on Level-1 Parent
        [ begin
            PointsStr = [[io_lib:format("~.2f", [X + OffX]), ",", io_lib:format("~.2f", [Y + OffY]), " "] || {X, Y} <- P],
            ParentQ = Q bsr 1, ParentR = R bsr 1,
            FillColor = parent_color(ParentQ, ParentR),
            io_lib:format("  <polygon points=\"~s\" fill=\"~s\" stroke=\"#adb5bd\" stroke-width=\"1\" />\n", [PointsStr, FillColor])
          end || {Q, R, _, L, P, _} <- hd(XYPolygonsByLevel), L == Level ],

        %% 2. Draw Overlapping Outlines for coarser levels
        lists:map(fun(LevelPolys) ->
            L_val = element(4, hd(LevelPolys)),
            if L_val == Level -> ""; 
               true ->
                Style = level_style(L_val, Levels),
                [ begin
                    PointsStr = [[io_lib:format("~.2f", [X + OffX]), ",", io_lib:format("~.2f", [Y + OffY]), " "] || {X, Y} <- P],
                    io_lib:format("  <polygon points=\"~s\" fill=\"none\" stroke=\"~s\" stroke-width=\"~s\" stroke-dasharray=\"~s\" stroke-opacity=\"0.6\" />\n", 
                                  [PointsStr, maps:get(color, Style), maps:get(width, Style), maps:get(dash, Style)])
                  end || {_, _, _, _, P, _} <- LevelPolys ]
            end
        end, tl(XYPolygonsByLevel)),
        
        %% 3. Draw Labels and Center Dots
        lists:map(fun({LevelPolys, I}) ->
            L_val = element(4, hd(LevelPolys)),
            Style = level_style(L_val, Levels),
            FontSize = case I of 1 -> 7; 2 -> 10; 3 -> 13 end,
            DY = (I - 2) * 25,
            [ begin
                [
                  io_lib:format("  <circle cx=\"~f\" cy=\"~f\" r=\"2\" fill=\"~s\" />\n", [CX + OffX, CY + OffY, maps:get(color, Style)]),
                  io_lib:format("  <g transform=\"translate(~f, ~f)\" font-family=\"sans-serif\" font-size=\"~p\" text-anchor=\"middle\">\n"
                                 "    <text y=\"~p\" fill=\"~s\">\n"
                                 "      <tspan x=\"0\" dy=\"0\" font-weight=\"bold\">~s</tspan>\n"
                                 "      <tspan x=\"0\" dy=\"1.2em\" font-size=\"~p\">~p,~p</tspan>\n"
                                 "    </text>\n"
                                 "  </g>\n", 
                                [CX + OffX, CY + OffY, FontSize, DY, maps:get(color, Style), Code, FontSize - 2, Q, R])
                ]
              end || {Q, R, Code, _, _, {CX, CY}} <- LevelPolys ]
        end, lists:zip(XYPolygonsByLevel, lists:seq(1, length(XYPolygonsByLevel)))),

        %% Input point
        io_lib:format("<circle cx=\"~f\" cy=\"~f\" r=\"5\" fill=\"#fa5252\" stroke=\"white\" stroke-width=\"2\" />\n", [PX, PY]),
        io_lib:format("<text x=\"~f\" y=\"~f\" font-family=\"sans-serif\" font-size=\"12\" font-weight=\"bold\" fill=\"#fa5252\" dy=\"-12\" text-anchor=\"middle\">Input Point</text>\n", [PX, PY]),
        
        %% Legend
        "<g transform=\"translate(20, 80)\" font-family=\"sans-serif\" font-size=\"10\">\n",
        [ io_lib:format("<g transform=\"translate(0, ~p)\">"
                        "<line x1=\"0\" y1=\"0\" x2=\"30\" y2=\"0\" stroke=\"~s\" stroke-width=\"~s\" stroke-dasharray=\"~s\" />"
                        "<text x=\"40\" y=\"4\" fill=\"#212529\">Level ~p (~s)</text>"
                        "</g>\n", 
                        [Idx*20, maps:get(color, Style), maps:get(width, Style), maps:get(dash, Style), L, Label])
          || {L, Idx, Label} <- lists:zip3(Levels, lists:seq(0, 2), ["Fine", "Mid (1.2x scaled)", "Coarse (1.2x scaled)"]),
             Style <- [level_style(L, Levels)] ],
        "</g>\n",
        
        "</svg>\n"
    ],
    
    FileName = "hexgrid.svg",
    file:write_file(FileName, SVG),
    io:format("Generated ~s with overlapping parent hexagons around [~f, ~f].~n", [FileName, Lat, Lon]).

hex_dist({Q1, R1}, {Q2, R2}) ->
    (abs(Q1 - Q2) + abs(Q1 + R1 - Q2 - R2) + abs(R1 - R2)) div 2.

latlon_to_xy_local(Lat, Lon, RefLat, RefLon) ->
    M_PER_DEG_LAT = 111319.49,
    CosLat = math:cos(Lat * math:pi() / 180.0),
    {(Lon - RefLon) * M_PER_DEG_LAT * CosLat,
     (Lat - RefLat) * M_PER_DEG_LAT}.

level_style(L, [L, _, _]) -> #{color => "#868e96", width => "1", dash => "none"};
level_style(L, [_, L, _]) -> #{color => "#339af0", width => "3", dash => "none"};
level_style(L, [_, _, L]) -> #{color => "#fa5252", width => "5", dash => "10,5"};
level_style(_, _) -> #{color => "#000", width => "1", dash => "none"}.

parent_color(Q, R) ->
    Colors = ["#f1f3f5", "#fff4e6", "#fdf2f2", "#f3f0ff", "#ebfbee", "#e6fcf5", "#fff9db"],
    Index = (abs(Q bxor R) rem length(Colors)) + 1,
    lists:nth(Index, Colors).
