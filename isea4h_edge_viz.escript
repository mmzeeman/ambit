#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa _build/default/lib/hexveil/ebin

main([ResStr]) ->
    Res = list_to_integer(ResStr),
    generate_edge_viz(Res);
main(_) ->
    io:format("Usage: ./isea4h_edge_viz.escript <res>~n"),
    io:format("Example: ./isea4h_edge_viz.escript 4~n").

generate_edge_viz(Res) ->
    io:format("Computing icosahedral structure...~n"),
    Verts = isea4h:ico_verts(),
    Faces = ico_faces(),
    VertTuple = list_to_tuple(Verts),

    AllEdges = lists:usort(lists:flatmap(
        fun({A, B, C}) ->
            [{min(A,B), max(A,B)}, {min(B,C), max(B,C)}, {min(A,C), max(A,C)}]
        end, Faces)),

    io:format("Building face edge polylines (~p edges)...~n", [length(AllEdges)]),
    FaceEdgeLines = [begin
        {Lat1, Lon1} = xyz_to_latlon(element(I+1, VertTuple)),
        {Lat2, Lon2} = xyz_to_latlon(element(J+1, VertTuple)),
        io_lib:format("[[~f,~f],[~f,~f]]", [Lat1, Lon1, Lat2, Lon2])
    end || {I, J} <- AllEdges],
    FaceEdgesJs = "[" ++ string:join(FaceEdgeLines, ",") ++ "]",

    io:format("Sampling global grid...~n"),
    Step = if Res >= 5 -> 1.0; true -> 2.0 end,
    Lats = float_range(-90.0, 90.0, Step),
    Lons = float_range(-180.0, 180.0, Step),
    GridDots = lists:flatmap(fun(Lat) ->
        [begin
             Code = isea4h:encode({Lat, Lon}, Res),
             Face = code_to_face(Code),
             io_lib:format("[~f,~f,~p]", [Lat, Lon, Face])
         end || Lon <- Lons]
    end, Lats),
    GridJs = "[" ++ string:join(GridDots, ",") ++ "]",

    io:format("Sampling edge points...~n"),
    N = 100,
    EdgeSamplePts = lists:flatmap(fun({I, J}) ->
        VA = element(I+1, VertTuple),
        VB = element(J+1, VertTuple),
        [begin
             {Lat, Lon} = xyz_to_latlon(P),
             Code = isea4h:encode({Lat, Lon}, Res),
             Face = code_to_face(Code),
             io_lib:format("[~f,~f,~p]", [Lat, Lon, Face])
         end || P <- interp_edge(VA, VB, N)]
    end, AllEdges),
    EdgeSampleJs = "[" ++ string:join(EdgeSamplePts, ",") ++ "]",

    io:format("Computing hex outlines for edge cells...~n"),
    EdgeCodes = lists:usort(lists:flatmap(fun({I, J}) ->
        VA = element(I+1, VertTuple),
        VB = element(J+1, VertTuple),
        [begin
             {Lat, Lon} = xyz_to_latlon(P),
             isea4h:encode({Lat, Lon}, Res)
         end || P <- interp_edge(VA, VB, N)]
    end, AllEdges)),
    io:format("  ~p unique hex cells on edges~n", [length(EdgeCodes)]),

    HexPolys = [begin
        Face = code_to_face(Code),
        Corners = isea4h:cell_geometry(Code),
        CornersJs = "[" ++ string:join(
            [io_lib:format("[~f,~f]", [La, Lo]) || {La, Lo} <- Corners], ",") ++ "]",
        io_lib:format("{\"face\":~p,\"coords\":~s}", [Face, CornersJs])
    end || Code <- EdgeCodes],
    HexJs = "[" ++ string:join(HexPolys, ",") ++ "]",

    io:format("Generating HTML...~n"),
    Html = generate_html(Res, FaceEdgesJs, GridJs, EdgeSampleJs, HexJs),

    FileName = "isea4h_edge_viz.html",
    ok = file:write_file(FileName, Html),
    io:format("Generated ~s~n", [FileName]).

%% --- Helper functions ---

ico_faces() ->
    [{0,1,2}, {0,2,3}, {0,3,4}, {0,4,5}, {0,5,1},
     {1,6,2}, {2,6,7}, {2,7,3}, {3,7,8}, {3,8,4},
     {4,8,9}, {4,9,5}, {5,9,10}, {5,10,1}, {1,10,6},
     {6,11,7}, {7,11,8}, {8,11,9}, {9,11,10}, {10,11,6}].

xyz_to_latlon({X, Y, Z}) ->
    D2R = math:pi() / 180.0,
    Lon = math:atan2(Y, X) / D2R,
    Zc = max(-1.0, min(1.0, Z)),
    Lat = math:asin(Zc) / D2R,
    {Lat, Lon}.

interp_edge({Ax,Ay,Az}, {Bx,By,Bz}, N) ->
    [begin
         T = I / (N - 1),
         Ix = Ax + T*(Bx - Ax),
         Iy = Ay + T*(By - Ay),
         Iz = Az + T*(Bz - Az),
         R = math:sqrt(Ix*Ix + Iy*Iy + Iz*Iz),
         {Ix/R, Iy/R, Iz/R}
     end || I <- lists:seq(0, N-1)].

code_to_face(<<FaceBin:1/binary, $-, _/binary>>) ->
    binary_to_integer(FaceBin, 20).

float_range(Min, Max, Step) ->
    N = trunc((Max - Min) / Step),
    [Min + I * Step || I <- lists:seq(0, N)].

generate_html(Res, FaceEdgesJs, GridJs, EdgeSampleJs, HexJs) ->
    ResStr = integer_to_list(Res),
    [
        "<!DOCTYPE html>\n<html><head>\n",
        "<meta charset=\"utf-8\">\n",
        "<title>ISEA4H Edge Gap Visualization &ndash; Res ", ResStr, "</title>\n",
        "<link rel=\"stylesheet\" href=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.css\" />\n",
        "<script src=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.js\"></script>\n",
        "<style>\n",
        "body { margin: 0; padding: 0; }\n",
        "#map { height: 100vh; }\n",
        ".legend { background: rgba(0,0,0,0.75); color: #eee; padding: 10px 12px;",
        " border-radius: 4px; font-size: 11px; max-height: 80vh; overflow-y: auto; }\n",
        ".legend b { font-size: 13px; }\n",
        ".legend-item { display: flex; align-items: center; margin: 3px 0; }\n",
        ".legend-swatch { width: 14px; height: 14px; margin-right: 6px;",
        " border-radius: 2px; flex-shrink: 0; }\n",
        "</style>\n",
        "</head>\n<body>\n<div id=\"map\"></div>\n<script>\n",
        "var faceColors=[\"#e6194b\",\"#3cb44b\",\"#ffe119\",\"#4363d8\",\"#f58231\",",
        "\"#911eb4\",\"#42d4f4\",\"#f032e6\",\"#bfef45\",\"#fabed4\",",
        "\"#469990\",\"#dcbeff\",\"#9A6324\",\"#fffac8\",\"#800000\",",
        "\"#aaffc3\",\"#808000\",\"#ffd8b1\",\"#000075\",\"#a9a9a9\"];\n\n",
        "var map=L.map('map').setView([20,0],2);\n",
        "L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',",
        "{attribution:'&copy; <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap</a>",
        " contributors &copy; <a href=\"https://carto.com/attributions\">CARTO</a>',",
        "maxZoom:18}).addTo(map);\n\n",
        "var faceEdges=", FaceEdgesJs, ";\n",
        "var gridDots=", GridJs, ";\n",
        "var edgeDots=", EdgeSampleJs, ";\n",
        "var hexPolys=", HexJs, ";\n\n",
        "var gridLayer=L.layerGroup();\n",
        "var edgeLayer=L.layerGroup();\n",
        "var hexLayer=L.layerGroup();\n",
        "var icoLayer=L.layerGroup();\n\n",
        "gridDots.forEach(function(d){\n",
        "  L.circleMarker([d[0],d[1]],{radius:2,color:faceColors[d[2]],",
        "fillColor:faceColors[d[2]],fillOpacity:0.85,weight:0}).addTo(gridLayer);\n",
        "});\n\n",
        "edgeDots.forEach(function(d){\n",
        "  L.circleMarker([d[0],d[1]],{radius:3,color:'#fff',weight:1,",
        "fillColor:faceColors[d[2]],fillOpacity:0.95}).addTo(edgeLayer);\n",
        "});\n\n",
        "hexPolys.forEach(function(h){\n",
        "  L.polygon(h.coords,{color:faceColors[h.face],weight:1.5,",
        "fillColor:faceColors[h.face],fillOpacity:0.2}).addTo(hexLayer);\n",
        "});\n\n",
        "faceEdges.forEach(function(e){\n",
        "  L.polyline(e,{color:'#fff',weight:2,opacity:0.7}).addTo(icoLayer);\n",
        "});\n\n",
        "gridLayer.addTo(map);\n",
        "edgeLayer.addTo(map);\n",
        "hexLayer.addTo(map);\n",
        "icoLayer.addTo(map);\n\n",
        "L.control.layers(null,{\n",
        "  'Grid (face colors)':gridLayer,\n",
        "  'Edge samples':edgeLayer,\n",
        "  'Hex outlines (edge cells)':hexLayer,\n",
        "  'Icosahedral face edges':icoLayer\n",
        "},{collapsed:false}).addTo(map);\n\n",
        "var legend=L.control({position:'bottomright'});\n",
        "legend.onAdd=function(){\n",
        "  var d=L.DomUtil.create('div','legend');\n",
        "  d.innerHTML='<b>Face Colors &ndash; Res ", ResStr, "</b><br>';\n",
        "  for(var i=0;i<20;i++){\n",
        "    d.innerHTML+='<div class=\"legend-item\"><div class=\"legend-swatch\" style=\"background:'+faceColors[i]+'\"></div>Face '+i+'</div>';\n",
        "  }\n",
        "  return d;\n",
        "};\n",
        "legend.addTo(map);\n",
        "</script></body></html>\n"
    ].
