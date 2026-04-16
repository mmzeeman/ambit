#!/usr/bin/env escript
%%! -pa _build/default/lib/hexveil/ebin

main([LatStr, LonStr, ResStr]) ->
    try
        Lat = parse_float(LatStr),
        Lon = parse_float(LonStr),
        Res = list_to_integer(ResStr),
        io:format("Generating visualization for ~f, ~f at res ~p...~n", [Lat, Lon, Res]),
        generate_viz(Lat, Lon, Res)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
main(_) ->
    io:format("Usage: ./triveil_viz.escript <lat> <lon> <res>~n"),
    io:format("Example: ./triveil_viz.escript 52.3676 4.9041 10~n").

parse_float(S) ->
    try list_to_float(S)
    catch error:badarg -> float(list_to_integer(S))
    end.

generate_viz(Lat, Lon, Res) ->
    Code = triveil:encode({Lat, Lon}, Res),
    Parent = triveil:parent(Code),
    GrandParent = triveil:parent(Parent),
    
    Siblings = [<<Parent/binary, (N + $0)>> || N <- lists:seq(0, 3)],
    N1 = triveil:neighbors(Code),
    N2 = triveil:neighbors_2(Code),
    
    Data = [
        to_json(GrandParent, "cyan", 5, 0.02),
        to_json(Parent, "red", 3, 0.05)
    ] ++ 
    [to_json(S, "#444", 1, 0.0) || S <- N2] ++
    [to_json(S, "orange", 1.5, 0.1) || S <- N1] ++
    [to_json(S, "green", 1, 0.2) || S <- Siblings] ++
    [to_json(Code, "blue", 3, 0.4)],
    
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
</script></body></html>", [Lat, Lon, string:join(Data, ",")]),
    
    file:write_file("triveil_viz.html", Html),
    io:format("Generated triveil_viz.html~n").

to_json(Code, Color, Weight, Opacity) ->
    Coords = triveil:cell_geometry(Code),
    CoordJson = "[" ++ string:join([io_lib:format("[~f, ~f]", [La, Lo]) || {La, Lo} <- Coords], ",") ++ "]",
    io_lib:format("{\"code\": \"~s\", \"color\": \"~s\", \"weight\": ~p, \"opacity\": ~f, \"coords\": ~s}",
                  [Code, Color, Weight, float(Opacity), CoordJson]).
