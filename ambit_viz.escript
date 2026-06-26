#!/usr/bin/env escript
%%! -pa _build/default/lib/ambit/ebin

main(["shape", TermStr, ResStr]) ->
    try
        GeoJSON = parse_erlang_term(TermStr),
        Res = list_to_integer(ResStr),
        io:format("Generating shape visualization at res ~p (corner mode)...~n", [Res]),
        generate_shape_viz(GeoJSON, Res, corner)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
main(["shape", TermStr, ResStr, ModeStr]) ->
    try
        GeoJSON = parse_erlang_term(TermStr),
        Res = list_to_integer(ResStr),
        Mode = parse_mode(ModeStr),
        io:format("Generating shape visualization at res ~p (~s mode)...~n", [Res, ModeStr]),
        generate_shape_viz(GeoJSON, Res, Mode)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
main(["nominatim", QueryStr, ResStr]) ->
    try
        Res = list_to_integer(ResStr),
        io:format("Searching nominatim for: ~s~n", [QueryStr]),
        GeoJSON = fetch_nominatim(QueryStr),
        io:format("Generating shape visualization at res ~p (corner mode)...~n", [Res]),
        generate_shape_viz(GeoJSON, Res, corner)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
main(["nominatim", QueryStr, ResStr, ModeStr]) ->
    try
        Res = list_to_integer(ResStr),
        Mode = parse_mode(ModeStr),
        io:format("Searching nominatim for: ~s~n", [QueryStr]),
        GeoJSON = fetch_nominatim(QueryStr),
        io:format("Generating shape visualization at res ~p (~s mode)...~n", [Res, ModeStr]),
        generate_shape_viz(GeoJSON, Res, Mode)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
main(["opendatasoft", PostcodeStr, ResStr]) ->
    try
        Res = list_to_integer(ResStr),
        io:format("Fetching postcode data from Opendatasoft for: ~s~n", [PostcodeStr]),
        GeoJSON = fetch_opendatasoft(PostcodeStr),
        io:format("Generating shape visualization at res ~p (corner mode)...~n", [Res]),
        generate_shape_viz(GeoJSON, Res, corner)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
main(["opendatasoft", PostcodeStr, ResStr, ModeStr]) ->
    try
        Res = list_to_integer(ResStr),
        Mode = parse_mode(ModeStr),
        io:format("Fetching postcode data from Opendatasoft for: ~s~n", [PostcodeStr]),
        GeoJSON = fetch_opendatasoft(PostcodeStr),
        io:format("Generating shape visualization at res ~p (~s mode)...~n", [Res, ModeStr]),
        generate_shape_viz(GeoJSON, Res, Mode)
    catch
        E:R:S ->
            io:format("Error: ~p:~p~n~p~n", [E, R, S])
    end;
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
    io:format("Usage:~n"),
    io:format("  ./ambit_viz.escript <lat> <lon> <res> [diameter_m] [mode]~n"),
    io:format("  ./ambit_viz.escript shape <erlang_geojson> <res> [mode]~n"),
    io:format("  ./ambit_viz.escript nominatim <query> <res> [mode]~n"),
    io:format("~n"),
    io:format("  mode: corner   - include triangle if at least one corner is within the disk (default)~n"),
    io:format("        centroid - include triangle only if its centroid is within the disk~n"),
    io:format("~n"),
    io:format("Examples:~n"),
    io:format("  ./ambit_viz.escript 52.3676 4.9041 10~n"),
    io:format("  ./ambit_viz.escript 52.3676 4.9041 13 1000~n"),
    io:format("  ./ambit_viz.escript 52.3676 4.9041 13 1000 centroid~n"),
    io:format("~n"),
    io:format("  ./ambit_viz.escript shape '#{<<\"type\">> => <<\"Polygon\">>, <<\"coordinates\">> => [[[4.8,52.3],[5.1,52.3],[5.1,52.5],[4.8,52.5],[4.8,52.3]]]}' 12~n"),
    io:format("  ./ambit_viz.escript shape '#{<<\"type\">> => <<\"Polygon\">>, <<\"coordinates\">> => [[[4.8,52.3],[5.1,52.3],[5.1,52.5],[4.8,52.5],[4.8,52.3]]]}' 12 centroid~n"),
    io:format("~n"),
    io:format("  ./ambit_viz.escript nominatim 'Hoofddorp,Netherlands' 12~n"),
    io:format("  ./ambit_viz.escript nominatim 'Hoofddorp,Netherlands' 12 centroid~n"),
    io:format("  ./ambit_viz.escript opendatasoft 2611 12~n"),
    io:format("  ./ambit_viz.escript opendatasoft 2611 12 centroid~n"),
    io:format("~n"),
    io:format("The erlang_geojson argument is an Erlang map term (as printed in the shell),~n"),
    io:format("representing a GeoJSON Polygon or MultiPolygon geometry. Coordinates are~n"),
    io:format("[Lon, Lat] pairs following the GeoJSON convention.~n"),
    io:format("~n"),
    io:format("The nominatim query is sent to nominatim.openstreetmap.org and the first~n"),
    io:format("result's polygon_geojson is used for the shape visualization.~n"),
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

parse_erlang_term(Str) ->
    {ok, Tokens, _} = erl_scan:string(Str ++ "."),
    case erl_parse:parse_term(Tokens) of
        {ok, Term} -> Term;
        {error, Err} -> erlang:error({bad_term, Err})
    end.

geojson_center(#{<<"type">> := <<"Polygon">>, <<"coordinates">> := [Outer0 | _]}) ->
    Outer = case Outer0 of
        [] -> [];
        [First | _] ->
            case lists:last(Outer0) of
                First -> lists:sublist(Outer0, length(Outer0)-1);
                _ -> Outer0
            end
    end,
    case Outer of
        [] -> erlang:error({bad_geojson, empty_coordinates});
        _ ->
            N = length(Outer),
            {SLon, SLat} = lists:foldl(
                fun([Lo, La | _], {SLo, SLa}) -> {SLo + float(Lo), SLa + float(La)} end,
                {0.0, 0.0}, Outer),
            {SLat / N, SLon / N}
    end;
geojson_center(#{<<"type">> := <<"MultiPolygon">>, <<"coordinates">> := [FirstPoly | _]}) ->
    geojson_center(#{<<"type">> => <<"Polygon">>, <<"coordinates">> => FirstPoly}).

fetch_nominatim(Query) ->
    case application:ensure_all_started(inets) of
        {ok, _} -> ok;
        {error, InetsReason} -> erlang:error({nominatim_request_failed, {inets_start_failed, InetsReason}})
    end,
    case application:ensure_all_started(ssl) of
        {ok, _} -> ok;
        {error, SslReason} -> erlang:error({nominatim_request_failed, {ssl_start_failed, SslReason}})
    end,
    QueryString = uri_string:compose_query([{"q", Query}, {"polygon_geojson", "1"}, {"format", "jsonv2"}, {"limit", "1"}]),
    Url = "https://nominatim.openstreetmap.org/search?" ++ QueryString,
    io:format("Fetching: ~s~n", [Url]),
    case httpc:request(
        get,
        {Url, [{"User-Agent", "ambit_viz/1.0 (https://github.com/mmzeeman/ambit)"}]},
        [{ssl, [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}]}],
        []) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            Results = json:decode(iolist_to_binary(Body)),
            case Results of
                [] ->
                    erlang:error({nominatim_no_results, Query});
                [First | _] ->
                    case maps:find(<<"geojson">>, First) of
                        {ok, GeoJSON} -> GeoJSON;
                        error -> erlang:error({nominatim_no_geojson, First})
                    end
            end;
        {ok, {{_, Status, Reason}, _Headers, _Body}} ->
            erlang:error({nominatim_http_error, Status, Reason});
        {error, Reason} ->
            erlang:error({nominatim_request_failed, Reason})
    end.

fetch_opendatasoft(Postcode) ->
    case application:ensure_all_started(inets) of
        {ok, _} -> ok;
        {error, InetsReason} -> erlang:error({opendatasoft_request_failed, {inets_start_failed, InetsReason}})
    end,
    case application:ensure_all_started(ssl) of
        {ok, _} -> ok;
        {error, SslReason} -> erlang:error({opendatasoft_request_failed, {ssl_start_failed, SslReason}})
    end,
    Url = "https://public.opendatasoft.com/api/records/1.0/search/?dataset=georef-netherlands-postcode-pc4&q=pc4_code:" ++ Postcode ++ "&rows=1&format=json",
    io:format("Fetching: ~s~n", [Url]),
    case httpc:request(
        get,
        {Url, [{"User-Agent", "ambit_viz/1.0"}]},
        [{ssl, [{verify, verify_none}]}],
        []) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            Response = json:decode(iolist_to_binary(Body)),
            NHits = maps:get(<<"nhits">>, Response),
            Records = maps:get(<<"records">>, Response),
            case {NHits, Records} of
                {0, _} ->
                    erlang:error({opendatasoft_no_results, Postcode});
                {_, []} ->
                    erlang:error({opendatasoft_no_results, Postcode});
                {_, [First | _]} ->
                    Fields = maps:get(<<"fields">>, First),
                    case maps:find(<<"geo_shape">>, Fields) of
                        {ok, GeoShape} -> 
                            io:format("Found postcode ~s~n", [maps:get(<<"pc4_code">>, Fields, <<"unknown">>)]),
                            GeoShape;
                        error -> 
                            erlang:error({opendatasoft_no_geojson, First})
                    end
            end;
        {ok, {{_, Status, Reason}, _Headers, _Body}} ->
            erlang:error({opendatasoft_http_error, Status, Reason});
        {error, Reason} ->
            erlang:error({opendatasoft_request_failed, Reason})
    end.

geojson_to_leaflet_js(#{<<"type">> := <<"Polygon">>, <<"coordinates">> := Rings}) ->
    RingsJs = [string:join(
        [io_lib:format("[~f,~f]", [float(La), float(Lo)]) || [Lo, La | _] <- Ring],
        ",") || Ring <- Rings],
    CoordsJs = "[" ++ string:join(["[" ++ R ++ "]" || R <- RingsJs], ",") ++ "]",
    io_lib:format(
        "L.polygon(~s, {color: 'red', weight: 2, fillOpacity: 0.05, dashArray: '6,4', "
        "interactive: false}).addTo(map);~n", [CoordsJs]);
geojson_to_leaflet_js(#{<<"type">> := <<"MultiPolygon">>, <<"coordinates">> := Polys}) ->
    lists:flatten([
        geojson_to_leaflet_js(#{<<"type">> => <<"Polygon">>, <<"coordinates">> => Rings})
        || Rings <- Polys
    ]).

generate_shape_viz(GeoJSON, Res, Mode) ->
    Codes = ambit:shape(GeoJSON, Res, Mode),
    io:format("Shape contains ~p codes at level ~p~n", [length(Codes), Res]),
    ModeStr = atom_to_list(Mode),

    {CenterLat, CenterLon} = geojson_center(GeoJSON),
    ShapeData = [to_json(C, "#e040e0", 1, 0.35) || C <- Codes],

    PolygonJs = geojson_to_leaflet_js(GeoJSON),

    InfoHtml = io_lib:format(
        "<div style='position:absolute;top:10px;right:10px;z-index:1000;"
        "background:white;padding:12px;border-radius:6px;box-shadow:0 2px 6px rgba(0,0,0,0.3);"
        "font-family:monospace;font-size:13px;'>"
        "<b>Shape Coverage</b><br>"
        "Level: ~p<br>"
        "Codes: ~p<br>"
        "Mode: ~s"
        "</div>",
        [Res, length(Codes), ModeStr]),

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
var map = L.map(\"map\").setView([~f, ~f], 12);
L.tileLayer(\"https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png\").addTo(map);

var data = [~s];
data.forEach(d => {
    L.polygon(d.coords, {color: d.color, weight: d.weight, fillOpacity: d.opacity, interactive: true}).addTo(map)
     .bindPopup(\"Code: \" + d.code);

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
</script></body></html>", [InfoHtml, CenterLat, CenterLon, string:join(ShapeData, ","), PolygonJs]),

    file:write_file("ambit_viz.html", Html),
    io:format("Generated ambit_viz.html~n").
