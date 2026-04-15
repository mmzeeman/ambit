#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa _build/default/lib/hexveil/ebin

main([LatStr, LonStr, ResStr]) ->
    Lat = list_to_float(LatStr),
    Lon = list_to_float(LonStr),
    Res = list_to_integer(ResStr),
    generate_viz(Lat, Lon, Res);
main(_) ->
    io:format("Usage: ./hexveil_viz.escript <lat> <lon> <res>~n"),
    io:format("Example: ./hexveil_viz.escript 52.3676 4.9041 10~n").

generate_viz(Lat, Lon, Res) ->
    %CenterCode = hexveil:encode({Lat, Lon}, Res),
    
    %% Get codes for 3 levels around the center
    Codes1 = get_codes({Lat, Lon}, max(1, Res-2)),
    Codes2 = get_codes({Lat, Lon}, max(1, Res-1)),
    Codes3 = get_codes({Lat, Lon}, Res),
    
    Poly1 = [to_poly(C) || C <- Codes1],
    Poly2 = [to_poly(C) || C <- Codes2],
    Poly3 = [to_poly(C) || C <- Codes3],
    
    Data1 = json_poly(Poly1),
    Data2 = json_poly(Poly2),
    Data3 = json_poly(Poly3),
    
    Html = io_lib:format("
<!DOCTYPE html>
<html><head>
<link rel=\"stylesheet\" href=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.css\" />
<script src=\"https://unpkg.com/leaflet@1.9.4/dist/leaflet.js\"></script>
<style>
#map { height: 100vh; margin: 0; }
.label { font-size: 12px; font-weight: bold; text-shadow: 0 0 3px white, 0 0 3px white; cursor: pointer; pointer-events: auto; }
</style>
</head>
<body>
<div id=\"map\"></div>
<script>
function copyCode(code) {
    var el = document.createElement('textarea');
    el.value = code;
    document.body.appendChild(el);
    el.select();
    document.execCommand('copy');
    document.body.removeChild(el);
    alert('Copied to clipboard: ' + code);
}
var map = L.map(\"map\").setView([~f, ~f], ~p);
L.tileLayer(\"https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png\").addTo(map);

var data1 = ~s;
var data2 = ~s;
var data3 = ~s;

data1.forEach(p => {
    L.polygon(p.coords, {color: \"red\", weight: 3, fillOpacity: 0}).addTo(map);
    L.marker(p.center, {
        icon: L.divIcon({
            className: 'label',
            html: '<span style=\"color:red\">' + p.code + '</span>',
            iconSize: [100, 20],
            iconAnchor: [50, 25]
        }),
        title: 'Click to copy: ' + p.code,
        interactive: true
    }).addTo(map).on('click', function() { copyCode(p.code); });
});
data2.forEach(p => {
    L.polygon(p.coords, {color: \"green\", weight: 2, fillOpacity: 0}).addTo(map);
    L.marker(p.center, {
        icon: L.divIcon({
            className: 'label',
            html: '<span style=\"color:green\">' + p.code + '</span>',
            iconSize: [100, 20],
            iconAnchor: [50, 10]
        }),
        title: 'Click to copy: ' + p.code,
        interactive: true
    }).addTo(map).on('click', function() { copyCode(p.code); });
});
data3.forEach(p => {
    L.polygon(p.coords, {color: \"blue\", weight: 1, fillOpacity: 0.1}).addTo(map);
    L.marker(p.center, {
        icon: L.divIcon({
            className: 'label',
            html: '<span style=\"color:blue\">' + p.code + '</span>',
            iconSize: [100, 20],
            iconAnchor: [50, -5]
        }),
        title: 'Click to copy: ' + p.code,
        interactive: true
    }).addTo(map).on('click', function() { copyCode(p.code); });
});
</script></body></html>", [Lat, Lon, zoom_level(Res), Data1, Data2, Data3]),
    
    FileName = "hexveil_viz.html",
    file:write_file(FileName, Html),
    io:format("Generated ~s~n", [FileName]).

get_codes(Coord, Res) ->
    Center = hexveil:encode(Coord, Res),
    N1 = hexveil:neighbors(Center),
    N2 = hexveil:neighbors_2(Center),
    [Center | N1 ++ N2].

to_poly(Code) ->
    Corners = hexveil:cell_geometry(Code),
    Center = hexveil:decode(Code),
    #{code => Code, coords => Corners, center => Center}.

json_poly(Polys) ->
    Items = [io_lib:format("{\"code\": \"~s\", \"center\": [~f, ~f], \"coords\": [~s]}", 
                           [to_str(Code), CLat, CLon, coords_to_json(Coords)])
             || #{code := Code, coords := Coords, center := {CLat, CLon}} <- Polys],
    "[" ++ string:join(Items, ",") ++ "]".

to_str(B) when is_binary(B) -> binary_to_list(B);
to_str(S) when is_list(S) -> S.

coords_to_json(Coords) ->
    "[" ++ string:join([io_lib:format("[~f, ~f]", [Lat, Lon]) || {Lat, Lon} <- Coords], ",") ++ "]".

zoom_level(Res) when Res < 3 -> 3;
zoom_level(Res) when Res < 5 -> 6;
zoom_level(Res) when Res < 7 -> 9;
zoom_level(Res) when Res < 9 -> 12;
zoom_level(_Res) -> 15.
