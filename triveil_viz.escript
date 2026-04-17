#!/usr/bin/env escript
%%! -pa _build/default/lib/hexveil/ebin

main([LatStr, LonStr, ResStr]) ->
    try
        Lat = parse_float(LatStr),
        Lon = parse_float(LonStr),
        Res = list_to_integer(ResStr),
        io:format("Generating visualization for ~f, ~f at res ~p...~n", [Lat, Lon, Res]),
        generate_viz(Lat, Lon, Res, undefined)
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
        io:format("Generating visualization for ~f, ~f at res ~p with ~f m disk...~n",
                  [Lat, Lon, Res, Diam]),
        generate_viz(Lat, Lon, Res, Diam)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
main(_) ->
    io:format("Usage: ./triveil_viz.escript <lat> <lon> <res> [diameter_m]~n"),
    io:format("~n"),
    io:format("Examples:~n"),
    io:format("  ./triveil_viz.escript 52.3676 4.9041 10~n"),
    io:format("  ./triveil_viz.escript 52.3676 4.9041 13 1000~n"),
    io:format("~n"),
    io:format("When diameter_m is given, the visualization shows the disk of~n"),
    io:format("triangular cells that approximate a circle of that diameter.~n"),
    io:format("Use triveil:optimal_level/1 to find the best resolution.~n").

parse_float(S) ->
    try list_to_float(S)
    catch error:badarg -> float(list_to_integer(S))
    end.

generate_viz(Lat, Lon, Res, MaybeDiam) ->
    Code = triveil:encode({Lat, Lon}, Res),
    Parent = triveil:parent(Code),
    GrandParent = triveil:parent(Parent),
    
    Siblings = [<<Parent/binary, (N + $0)>> || N <- lists:seq(0, 3)],
    N1 = triveil:neighbors(Code),
    N2 = triveil:neighbors_2(Code),
    
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
            DiskCodes = triveil:disk({Lat, Lon}, Res, Diam),
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
                "Optimal level: ~p"
                "</div>",
                [Diam, Res, length(DiskCodes), triveil:optimal_level(Diam)]),
            {DLayer, Info}
    end,

    %% Disk codes drawn first (below), then hierarchy on top
    Data = DiskData ++ BaseData,

    %% Reference circle (true circle at the requested diameter)
    CircleJs = case MaybeDiam of
        undefined -> "";
        D ->
            io_lib:format(
                "L.circle([~f, ~f], {radius: ~f, color: '#e040e0', weight: 2, "
                "dashArray: '6,4', fill: false, interactive: false}).addTo(map)"
                ".bindPopup('Reference circle: ~f m diameter');~n",
                [Lat, Lon, D / 2.0, D])
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
</script></body></html>", [DiskInfo, Lat, Lon, string:join(Data, ","), CircleJs]),
    
    file:write_file("triveil_viz.html", Html),
    io:format("Generated triveil_viz.html~n").

to_json(Code, Color, Weight, Opacity) ->
    Coords = triveil:cell_geometry(Code),
    CoordJson = "[" ++ string:join([io_lib:format("[~f, ~f]", [La, Lo]) || {La, Lo} <- Coords], ",") ++ "]",
    io_lib:format("{\"code\": \"~s\", \"color\": \"~s\", \"weight\": ~p, \"opacity\": ~f, \"coords\": ~s}",
                  [Code, Color, Weight, float(Opacity), CoordJson]).
