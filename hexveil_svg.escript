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
    main([LatStr, LonStr, LevelStr, "2"]);
main(_) ->
    io:format("Usage: ./hexveil_svg <lat> <lon> <level> [radius]~n"),
    io:format("Example: ./hexveil_svg 52.3616 4.8784 30 3~n").

generate_svg(Lat, Lon, Level, Radius) ->
    Levels = [Level, Level-1, Level-2],
    FineDigits = hexveil:encode(Lat, Lon),
    LevelDigits = hexveil:coarsen(FineDigits, Level),
    
    Expand = fun(Set) ->
        lists:usort(lists:append([ [D | hexveil:neighbors(D)] || D <- Set ]))
    end,
    GridAtLevel = lists:foldl(fun(_, Acc) -> Expand(Acc) end, [LevelDigits], lists:seq(1, Radius)),

    Project = fun({PLat, PLon}) ->
        {X, Y} = latlon_to_xy_local(PLat, PLon, Lat, Lon),
        {X, -Y}
    end,

    %% Project all unique hexes at all requested levels
    XYPolygonsByLevel = [begin
        UniqueDigits = lists:usort([ hexveil:coarsen(D, L) || D <- GridAtLevel ]),
        [ begin
            Corners = hexveil:cell_geometry(D),
            Code = hexveil:display(D),
            {CLat, CLon} = hexveil:decode(D),
            CenterXY = Project({CLat, CLon}),
            
            %% Use true geometric scale (1.0) for all levels
            Scale = 1.0,
            XYCorners = [begin 
                            {CX, CY} = Project(C),
                            {Center_X, Center_Y} = CenterXY,
                            {Center_X + (CX - Center_X) * Scale, Center_Y + (CY - Center_Y) * Scale}
                         end || C <- Corners],

            {D, Code, L, XYCorners, CenterXY}
          end || D <- UniqueDigits ]
    end || L <- Levels],

    Flattened = lists:flatten(XYPolygonsByLevel),
    AllX = [X || {_, _, _, P, {CX, _}} <- Flattened, {X, _} <- [CX|P]],
    AllY = [Y || {_, _, _, P, {_, CY}} <- Flattened, {_, Y} <- [CY|P]],
    
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
        
        io_lib:format("<text x=\"20\" y=\"30\" font-family=\"sans-serif\" font-size=\"16\" font-weight=\"bold\" fill=\"#212529\">HexVeil V3 Aperture-3 Hierarchy</text>\n", []),
        io_lib:format("<text x=\"20\" y=\"55\" font-family=\"sans-serif\" font-size=\"12\" fill=\"#495057\">Center: ~f, ~f | Levels: ~w</text>\n", [Lat, Lon, Levels]),

        %% 1. Draw Fine Polygons with TINT based on Level-1 Parent
        [ begin
            PointsStr = [[io_lib:format("~.2f", [X + OffX]), ",", io_lib:format("~.2f", [Y + OffY]), " "] || {X, Y} <- P],
            ParentDigits = hexveil:coarsen(D, Level - 1),
            FillColor = parent_color(ParentDigits),
            io_lib:format("  <polygon points=\"~s\" fill=\"~s\" stroke=\"#adb5bd\" stroke-width=\"1\" />\n", [PointsStr, FillColor])
          end || {D, _, L, P, _} <- hd(XYPolygonsByLevel), L == Level ],

        %% 2. Draw Outlines for coarser levels
        lists:map(fun(LevelPolys) ->
            L_val = element(3, hd(LevelPolys)),
            if L_val == Level -> ""; 
               true ->
                Style = level_style(L_val, Levels),
                [ begin
                    PointsStr = [[io_lib:format("~.2f", [X + OffX]), ",", io_lib:format("~.2f", [Y + OffY]), " "] || {X, Y} <- P],
                    io_lib:format("  <polygon points=\"~s\" fill=\"none\" stroke=\"~s\" stroke-width=\"~s\" stroke-dasharray=\"~s\" stroke-opacity=\"0.7\" />\n", 
                                  [PointsStr, maps:get(color, Style), maps:get(width, Style), maps:get(dash, Style)])
                  end || {_, _, _, P, _} <- LevelPolys ]
            end
        end, tl(XYPolygonsByLevel)),
        
        %% 3. Draw Labels and Center Dots
        lists:map(fun({LevelPolys, I}) ->
            L_val = element(3, hd(LevelPolys)),
            Style = level_style(L_val, Levels),
            FontSize = case I of 1 -> 8; 2 -> 11; 3 -> 14 end,
            DY = (I - 2) * 25,
            [ begin
                [
                  io_lib:format("  <circle cx=\"~f\" cy=\"~f\" r=\"2\" fill=\"~s\" />\n", [CX + OffX, CY + OffY, maps:get(color, Style)]),
                  io_lib:format("  <g transform=\"translate(~f, ~f)\" font-family=\"sans-serif\" font-size=\"~p\" text-anchor=\"middle\">\n"
                                 "    <text y=\"~p\" fill=\"~s\">\n"
                                 "      <tspan x=\"0\" dy=\"0\" font-weight=\"bold\">~s</tspan>\n"
                                 "    </text>\n"
                                 "  </g>\n", 
                                [CX + OffX, CY + OffY, FontSize, DY, maps:get(color, Style), Code])
                ]
              end || {_, Code, _, _, {CX, CY}} <- LevelPolys ]
        end, lists:zip(XYPolygonsByLevel, lists:seq(1, length(XYPolygonsByLevel)))),

        %% Input point
        io_lib:format("<circle cx=\"~f\" cy=\"~f\" r=\"5\" fill=\"#fa5252\" stroke=\"white\" stroke-width=\"2\" />\n", [PX, PY]),
        io_lib:format("<text x=\"~f\" y=\"~f\" font-family=\"sans-serif\" font-size=\"12\" font-weight=\"bold\" fill=\"#fa5252\" dy=\"-12\" text-anchor=\"middle\">Input Point</text>\n", [PX, PY]),
        
        %% Legend
        "<g transform=\"translate(20, 80)\" font-family=\"sans-serif\" font-size=\"10\">\n",
        [ io_lib:format("<g transform=\"translate(0, ~p)\">"
                        "<line x1=\"0\" y1=\"0\" x2=\"30\" y2=\"0\" stroke=\"~s\" stroke-width=\"~s\" stroke-dasharray=\"~s\" />"
                        "<text x=\"40\" y=\"4\" fill=\"#212529\">Level ~p</text>"
                        "</g>\n", 
                        [Idx*20, maps:get(color, Style), maps:get(width, Style), maps:get(dash, Style), L])
          || {L, Idx} <- lists:zip(Levels, lists:seq(0, 2)),
             Style <- [level_style(L, Levels)] ],
        "</g>\n",
        
        "</svg>\n"
    ],
    
    %% Generate one SVG per level
    lists:foreach(fun({L, Polys}) ->
        FileName = io_lib:format("hexgrid_v3_L~p.svg", [L]),
        write_level_svg(FileName, Lat, Lon, L, Polys, Project, OffX, OffY, Width, Height, PX, PY)
    end, lists:zip(Levels, XYPolygonsByLevel)),

    %% Final combined filename for reference
    FileName = "hexgrid_v3_combined.svg",
    file:write_file(FileName, SVG),
    io:format("Generated ~s and separate files for levels ~w.~n", [FileName, Levels]).

write_level_svg(FileName, Lat, Lon, Level, Polys, _Project, OffX, OffY, Width, Height, PX, PY) ->
    SVG = [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
        io_lib:format("<svg width=\"~f\" height=\"~f\" xmlns=\"http://www.w3.org/2000/svg\">\n", [Width, Height]),
        "<rect width=\"100%\" height=\"100%\" fill=\"#f8f9fa\" />\n",
        io_lib:format("<text x=\"20\" y=\"30\" font-family=\"sans-serif\" font-size=\"16\" font-weight=\"bold\" fill=\"#212529\">HexVeil V3 - Level ~p</text>\n", [Level]),
        io_lib:format("<text x=\"20\" y=\"55\" font-family=\"sans-serif\" font-size=\"12\" fill=\"#495057\">Center: ~f, ~f</text>\n", [Lat, Lon]),

        [ begin
            PointsStr = [[io_lib:format("~.2f", [X + OffX]), ",", io_lib:format("~.2f", [Y + OffY]), " "] || {X, Y} <- P],
            FillColor = parent_color(D),
            [
              io_lib:format("  <polygon points=\"~s\" fill=\"~s\" stroke=\"#adb5bd\" stroke-width=\"1\" />\n", [PointsStr, FillColor]),
              io_lib:format("  <circle cx=\"~f\" cy=\"~f\" r=\"2\" fill=\"#495057\" />\n", [CX + OffX, CY + OffY]),
              io_lib:format("  <text x=\"~f\" y=\"~f\" font-family=\"sans-serif\" font-size=\"10\" text-anchor=\"middle\" fill=\"#212529\" dy=\"12\">~s</text>\n", 
                            [CX + OffX, CY + OffY, Code])
            ]
          end || {D, Code, _, P, {CX, CY}} <- Polys ],

        %% Input point
        io_lib:format("<circle cx=\"~f\" cy=\"~f\" r=\"5\" fill=\"#fa5252\" stroke=\"white\" stroke-width=\"2\" />\n", [PX, PY]),
        "</svg>\n"
    ],
    file:write_file(FileName, SVG).

latlon_to_xy_local(Lat, Lon, RefLat, RefLon) ->
    M_PER_DEG_LAT = 111319.49,
    CosLat = math:cos(Lat * math:pi() / 180.0),
    {(Lon - RefLon) * M_PER_DEG_LAT * CosLat,
     (Lat - RefLat) * M_PER_DEG_LAT}.

level_style(L, [L, _, _]) -> #{color => "#868e96", width => "1", dash => "none"};
level_style(L, [_, L, _]) -> #{color => "#339af0", width => "3", dash => "none"};
level_style(L, [_, _, L]) -> #{color => "#fa5252", width => "5", dash => "10,5"};
level_style(_, _) -> #{color => "#000", width => "1", dash => "none"}.

parent_color(Digits) ->
    Colors = ["#f1f3f5", "#fff4e6", "#fdf2f2", "#f3f0ff", "#ebfbee", "#e6fcf5", "#fff9db"],
    %% Hash Digits to pick a color
    Hash = erlang:phash2(Digits),
    Index = (Hash rem length(Colors)) + 1,
    lists:nth(Index, Colors).
