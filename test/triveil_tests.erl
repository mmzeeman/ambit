
-module(triveil_tests).
-include_lib("eunit/include/eunit.hrl").

%% Round-trip encode/decode
roundtrip_test() ->
    Locations = [
        {0.0, 0.0},
        {20.0, 10.0},
        {45.0, -30.0},
        {-10.0, 120.0},
        {90.0, 0.0}, % North Pole
        {-90.0, 0.0} % South Pole
    ],
    lists:foreach(fun({Lat, Lon}) ->
        Res = 7,
        Code = triveil:encode({Lat, Lon}, Res),
        {DLat, DLon} = triveil:decode(Code),
        
        %% Triangles at Res 7 are small, but let's be generous with error
        MaxErr = 1.0,
        IsPole = abs(Lat) > 89.0,
        LonMatch = IsPole orelse abs(DLon - Lon) < MaxErr orelse abs(abs(DLon - Lon) - 360.0) < MaxErr,
        LatMatch = abs(DLat - Lat) < MaxErr,
        ?assert(LonMatch andalso LatMatch, 
                io_lib:format("At (~p, ~p) got (~p, ~p) code ~p", [Lat, Lon, DLat, DLon, Code]))
    end, Locations).

%% parent should remove one digit at the end
parent_test() ->
    Code = triveil:encode({20.0, 10.0}, 6),
    Parent = triveil:parent(Code),
    [_, Digits] = string:split(binary_to_list(Code), "-"),
    [_, Pdigits] = string:split(binary_to_list(Parent), "-"),
    ?assertEqual(length(Digits)-1, length(Pdigits)).

%% neighbors returns codes for adjacent triangles
neighbors_test() ->
    Code = triveil:encode({20.0, 10.0}, 5),
    N = triveil:neighbors(Code),
    %% Triangle neighbors: could be 3 (edge) or 12 (including vertices)
    %% The implementation uses 12 directions.
    ?assert(length(N) > 0),
    lists:foreach(fun(C) -> ?assert(is_binary(C)) end, N).

%% cell_geometry returns 3 corner coordinates as {Lat, Lon} floats
cell_geometry_test() ->
    Code = triveil:encode({20.0, 10.0}, 6),
    Corners = triveil:cell_geometry(Code),
    ?assertEqual(3, length(Corners)),
    lists:foreach(fun({Lat, Lon}) ->
        ?assert(is_float(Lat)),
        ?assert(is_float(Lon))
    end, Corners).

%% Test neighborhood consistency
neighbor_consistency_test() ->
    Coord = {52.3676, 4.9041},
    Res = 10,
    Code = triveil:encode(Coord, Res),
    {Lat, Lon} = triveil:decode(Code),
    N1 = triveil:neighbors(Code),
    ?assert(length(N1) > 0),
    lists:foreach(fun(NCode) ->
        {NLat, NLon} = triveil:decode(NCode),
        DLon = abs(NLon - Lon),
        ActualDLon = lists:min([DLon, abs(DLon - 360.0)]),
        case abs(NLat - Lat) < 1.0 andalso ActualDLon < 1.0 of
            true -> ok;
            false ->
                io:format(user, "~nNeighbor ~s at (~p, ~p) too far from (~p, ~p) code ~s~n", 
                          [NCode, NLat, NLon, Lat, Lon, Code]),
                ?assert(false)
        end
    end, N1).
