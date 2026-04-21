#!/usr/bin/env escript
%%! -pa _build/default/lib/ambit/ebin

main([LatStr, LonStr, ResStr]) ->
    try
        Lat = parse_float(LatStr),
        Lon = parse_float(LonStr),
        Res = list_to_integer(ResStr),
        io:format("Generating visualization for ~f, ~f at res ~p...~n", [Lat, Lon, Res]),
        generate_viz(Lat, Lon, Res, undefined, corner)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
main([LatStr, LonStr, ResStr, DiamStr]) ->
    try
        Lat = parse_float(LatStr),
        Lon = parse_float(LonStr),
        Res = list_to_integer(ResStr),
        Diam = parse_float(DiamStr),
        io:format("Generating visualization for ~f, ~f at res ~p with ~f m disk (corner mode)...~n",
                  [Lat, Lon, Res, Diam]),
        generate_viz(Lat, Lon, Res, Diam, corner)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
main([LatStr, LonStr, ResStr, DiamStr, ModeStr]) ->
    try
        Lat = parse_float(LatStr),
        Lon = parse_float(LonStr),
        Res = list_to_integer(ResStr),
        Diam = parse_float(DiamStr),
        Mode = parse_mode(ModeStr),
        io:format("Generating visualization for ~f, ~f at res ~p with ~f m disk (~s mode)...~n",
                  [Lat, Lon, Res, Diam, ModeStr]),
        generate_viz(Lat, Lon, Res, Diam, Mode)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
main(_) ->
    io:format("Usage: ./ambit_viz.escript <lat> <lon> <res> [diameter_m] [mode]~n"),
    io:format("~n"),
    io:format("  mode: corner   - include triangle if at least one corner is within the disk (default)~n"),
    io:format("        centroid - include triangle only if its centroid is within the disk~n"),
    io:format("~n"),
    io:format("Examples:~n"),
    io:format("  ./ambit_viz.escript 52.3676 4.9041 10~n"),
    io:format("  ./ambit_viz.escript 52.3676 4.9041 13 1000~n"),
    io:format("  ./ambit_viz.escript 52.3676 4.9041 13 1000 centroid~n"),
    io:format("~n"),
    io:format("When diameter_m is given, the visualization shows the disk of~n"),
    io:format("triangular cells that approximate a circle of that diameter.~n"),
    io:format("Use ambit:optimal_level/1 to find the best resolution.~n").

parse_float(S) ->
    try list_to_float(S)
    catch error:badarg -> float(list_to_integer(S))
    end.

parse_mode("corner") -> corner;
parse_mode("centroid") -> centroid;
parse_mode(Other) -> erlang:error({bad_mode, Other}).

generate_viz(Lat, Lon, Res, MaybeDiam, Mode) ->
    Code = ambit:encode({Lat, Lon}, Res),
    Parent = ambit:parent(Code),
    GrandParent = ambit:parent(Parent),
    
    Siblings = [<<Parent/binary, (N + $0)>> || N <- lists:seq(0, 3)],
    N1 = ambit:neighbors(Code),
    N2 = ambit:neighbors_2(Code),
    
    %% Base layers: hierarchy + neighbors
    BaseData = [
        to_json(GrandParent, "cyan", 5, 0.02),
        to_json(Parent, "red", 3, 0.05)
    ] ++ 
    [to_json(S, "#444", 1, 0.0) || S <- N2] ++
    [to_json(S, "orange", 1.5, 0.1) || S <- N1] ++
    [to_json(S, "green", 1, 0.2) || S <- Siblings] ++
    [to_json(Code, "blue", 3, 0.4)],

    %% Optional disk layer
    {DiskData, DiskInfo} = case MaybeDiam of
        undefined -> {[], ""};
        Diam ->
            DiskCodes = ambit:disk({Lat, Lon}, Res, Diam, Mode),
            ModeStr = atom_to_list(Mode),
            io:format("Disk contains ~p codes at level ~p~n", [length(DiskCodes), Res]),
            DLayer = [to_json(DC, "#e040e0", 1, 0.35) || DC <- DiskCodes],
            Info = io_lib:format(
                "<div style='position:absolute;top:10px;right:10px;z-index:1000;"
                "background:white;padding:12px;border-radius:6px;box-shadow:0 2px 6px rgba(0,0,0,0.3);"
                "font-family:monospace;font-size:13px;'>"
                "<b>Visibility Disk</b><br>"
                "Diameter: ~f m<br>"
                "Level: ~p<br>"
                "Codes: ~p<br>"
                "Mode: ~s<br>"
                "Optimal level: ~p"
                "</div>",
                [Diam, Res, length(DiskCodes), ModeStr, ambit:optimal_level(Diam)]),
            {DLayer, Info}
    end,

    %% Disk codes drawn first (below), then hierarchy on top
    Data = DiskData ++ BaseData,

    %% Red dot at the exact user location
    RedDotJs = io_lib:format(
        "L.circleMarker([~f, ~f], {radius: 5, color: 'red', fillColor: 'red', "
        "fillOpacity: 1.0, weight: 1, interactive: true}).addTo(map)"
        ".bindPopup('Exact location: ~f, ~f');~n",
        [Lat, Lon, Lat, Lon]),

    %% Reference circle centered on the privacy center (level-15 orthocenter)
    %% This matches the disk center used by ambit:disk/3
    CircleJs = case MaybeDiam of
        undefined -> "";
        D ->
            {OLat, OLon} = ambit:disk_center({Lat, Lon}),
            io_lib:format(
                "L.circle([~f, ~f], {radius: ~f, color: '#e040e0', weight: 2, "
                "dashArray: '6,4', fill: false, interactive: false}).addTo(map)"
                ".bindPopup('Reference circle: ~f m diameter (centered on privacy center)');~n",
                [OLat, OLon, D / 2.0, D])
    end,

    Html = io_lib:format("
<!DOCTYPE html>
<html><head>
<link rel=\"stylesheet\" href=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.css\" />
<script src=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.js\"></script>
<style>
#map { height: 100vh; margin: 0; }
.label { font-size: 10px; font-weight: bold; text-shadow: 0 0 2px white; pointer-events: none; }
</style>
</head>
<body>
~s
<div id=\"map\"></div>
<script>
var map = L.map(\"map\").setView([~f, ~f], 15);
L.tileLayer(\"https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png\").addTo(map);

var data = [~s];
data.forEach(d => {
    L.polygon(d.coords, {color: d.color, weight: d.weight, fillOpacity: d.opacity, interactive: true}).addTo(map)
     .bindPopup(\"Code: \" + d.code);
    
    // Add visible label at the centroid
    var center = [0, 0];
    d.coords.forEach(c => { center[0] += c[0]; center[1] += c[1]; });
    center[0] /= d.coords.length;
    center[1] /= d.coords.length;

    L.marker(center, {
        icon: L.divIcon({
            className: 'label',
            html: '<span style=\"color:' + d.color + '\">' + d.code.split('-')[1].slice(-3) + '</span>',
            iconSize: [40, 12],
            iconAnchor: [20, 6]
        })
    }).addTo(map);
});
~s
~s
</script></body></html>", [DiskInfo, Lat, Lon, string:join(Data, ","), CircleJs, RedDotJs]),
    
    file:write_file("ambit_viz.html", Html),
    io:format("Generated ambit_viz.html~n").

to_json(Code, Color, Weight, Opacity) ->
    Coords = ambit:cell_geometry(Code),
    CoordJson = "[" ++ string:join([io_lib:format("[~f, ~f]", [La, Lo]) || {La, Lo} <- Coords], ",") ++ "]",
    io_lib:format("{\"code\": \"~s\", \"color\": \"~s\", \"weight\": ~p, \"opacity\": ~f, \"coords\": ~s}",
                  [Code, Color, Weight, float(Opacity), CoordJson]).
