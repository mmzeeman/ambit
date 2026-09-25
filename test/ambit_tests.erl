
-module(ambit_tests).
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
        Code = ambit:encode({Lat, Lon}, Res),
        {DLat, DLon} = ambit:decode(Code),
        
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
    Code = ambit:encode({20.0, 10.0}, 6),
    Parent = ambit:parent(Code),
    [_, Digits] = string:split(binary_to_list(Code), "-"),
    [_, Pdigits] = string:split(binary_to_list(Parent), "-"),
    ?assertEqual(length(Digits)-1, length(Pdigits)).

%% neighbors returns codes for adjacent triangles
neighbors_test() ->
    Code = ambit:encode({20.0, 10.0}, 5),
    N = ambit:neighbors(Code),
    %% Triangle neighbors: could be 3 (edge) or 12 (including vertices)
    %% The implementation uses 12 directions.
    ?assert(length(N) > 0),
    lists:foreach(fun(C) -> ?assert(is_binary(C)) end, N).

%% cell_geometry returns 3 corner coordinates as {Lat, Lon} floats
cell_geometry_test() ->
    Code = ambit:encode({20.0, 10.0}, 6),
    {C1, C2, C3} = ambit:cell_geometry(Code),
    lists:foreach(fun({Lat, Lon}) ->
        ?assert(is_float(Lat)),
        ?assert(is_float(Lon))
    end, [C1, C2, C3]).

%% Test neighborhood consistency
neighbor_consistency_test() ->
    Coord = {52.3676, 4.9041},
    Res = 10,
    Code = ambit:encode(Coord, Res),
    {Lat, Lon} = ambit:decode(Code),
    N1 = ambit:neighbors(Code),
    ?assert(length(N1) > 0),
    lists:foreach(fun(NCode) ->
        {NLat, NLon} = ambit:decode(NCode),
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

%% optimal_level returns a level whose cell diameter closely matches the target
optimal_level_test() ->
    %% Empirical cell diameters (at Amsterdam):
    %%   L13 ≈  969 m, L14 ≈ 485 m, L16 ≈ 121 m
    ?assertEqual(13, ambit:optimal_level(1000)),
    ?assertEqual(14, ambit:optimal_level(500)),
    ?assertEqual(16, ambit:optimal_level(100)).

%% optimal_level clamps to valid range
optimal_level_clamp_test() ->
    ?assertEqual(1,  ambit:optimal_level(100000000)),  %% huge → level 1
    ?assertEqual(24, ambit:optimal_level(0.001)).      %% tiny → level 24

%% optimal_level result can be used directly with disk/3
optimal_level_disk_integration_test() ->
    Diameter = 1000,
    Res = ambit:optimal_level(Diameter),
    Codes = ambit:disk({52.3676, 4.9041}, Res, Diameter),
    %% At optimal level, disk should return a small number of codes (1-4)
    ?assert(length(Codes) >= 1 andalso length(Codes) =< 10,
            io_lib:format("Expected 1-10 codes at optimal level ~B, got ~B", [Res, length(Codes)])).

%% disk_center returns the same point regardless of which resolution
%% the caller intends to use for disk tiles
disk_center_stable_test() ->
    Loc = {52.37456, 4.87249},
    Center = ambit:disk_center(Loc),
    ?assert(is_tuple(Center)),
    {CLat, CLon} = Center,
    ?assert(is_float(CLat)),
    ?assert(is_float(CLon)),
    %% Center should be near the input location (within ~1 km at level 15)
    Dist = great_circle_m(Loc, Center),
    ?assert(Dist < 1000.0,
            io_lib:format("Privacy center too far from input: ~f m", [Dist])).

%% Two different points in the same level-15 cell should get the same center
disk_center_same_cell_test() ->
    %% Two nearby points that should fall in the same level-15 triangle
    Loc1 = {52.37456, 4.87249},
    Loc2 = {52.37457, 4.87250},
    C1 = ambit:disk_center(Loc1),
    C2 = ambit:disk_center(Loc2),
    ?assertEqual(C1, C2).

%% disk/4 with centroid mode returns a subset of corner mode
disk_mode_centroid_subset_test() ->
    Loc = {52.3676, 4.9041},
    Res = 13,
    Diam = 1000,
    CornerCodes = lists:sort(ambit:disk(Loc, Res, Diam, corner)),
    CentroidCodes = lists:sort(ambit:disk(Loc, Res, Diam, centroid)),
    %% centroid mode should return fewer (or equal) codes
    ?assert(length(CentroidCodes) =< length(CornerCodes),
            io_lib:format("centroid (~B) should be <= corner (~B)",
                          [length(CentroidCodes), length(CornerCodes)])),
    %% every centroid code should also appear in corner codes
    lists:foreach(fun(C) ->
        ?assert(lists:member(C, CornerCodes),
                io_lib:format("centroid code ~s not in corner set", [C]))
    end, CentroidCodes).

%% disk/3 (no mode) should behave like corner mode
disk_default_mode_test() ->
    Loc = {52.3676, 4.9041},
    Res = 13,
    Diam = 1000,
    Default = lists:sort(ambit:disk(Loc, Res, Diam)),
    Corner = lists:sort(ambit:disk(Loc, Res, Diam, corner)),
    ?assertEqual(Default, Corner).

great_circle_m({Lat1, Lon1}, {Lat2, Lon2}) ->
    D2R = 0.017453292519943295,
    Lo1 = Lon1 * D2R, La1 = Lat1 * D2R,
    Lo2 = Lon2 * D2R, La2 = Lat2 * D2R,
    X1 = math:cos(La1)*math:cos(Lo1), Y1 = math:cos(La1)*math:sin(Lo1), Z1 = math:sin(La1),
    X2 = math:cos(La2)*math:cos(Lo2), Y2 = math:cos(La2)*math:sin(Lo2), Z2 = math:sin(La2),
    Dot = max(-1.0, min(1.0, X1*X2 + Y1*Y2 + Z1*Z2)),
    math:acos(Dot) * 6371000.0.

%% A simple bounding-box polygon around Amsterdam
shape_polygon_test() ->
    %% Rough bounding box: 52.3N-52.5N, 4.8E-5.1E
    GeoJSON = #{<<"type">> => <<"Polygon">>,
                <<"coordinates">> => [[
                    [4.8, 52.3], [5.1, 52.3], [5.1, 52.5], [4.8, 52.5], [4.8, 52.3]
                ]]},
    Codes = ambit:shape(GeoJSON, 12),
    ?assert(length(Codes) > 0),
    lists:foreach(fun(C) -> ?assert(is_binary(C)) end, Codes).

%% corner mode returns at least as many codes as centroid mode
shape_mode_test() ->
    GeoJSON = #{<<"type">> => <<"Polygon">>,
                <<"coordinates">> => [[
                    [4.8, 52.3], [5.1, 52.3], [5.1, 52.5], [4.8, 52.5], [4.8, 52.3]
                ]]},
    Res = 11,
    Corner   = ambit:shape(GeoJSON, Res, corner),
    Centroid = ambit:shape(GeoJSON, Res, centroid),
    ?assert(length(Corner) >= length(Centroid)).

%% MultiPolygon returns union of per-polygon results
shape_multipolygon_test() ->
    P1 = [[4.8, 52.3], [5.1, 52.3], [5.1, 52.5], [4.8, 52.5], [4.8, 52.3]],
    P2 = [[13.3, 52.4], [13.6, 52.4], [13.6, 52.6], [13.3, 52.6], [13.3, 52.4]],
    GeoJSON = #{<<"type">> => <<"MultiPolygon">>,
                <<"coordinates">> => [[P1], [P2]]},
    Codes = ambit:shape(GeoJSON, 10),
    ?assert(length(Codes) > 0).

%% Every returned code's centroid should be decodable
shape_all_decodable_test() ->
    GeoJSON = #{<<"type">> => <<"Polygon">>,
                <<"coordinates">> => [[
                    [4.85, 52.35], [4.95, 52.35], [4.95, 52.45], [4.85, 52.45], [4.85, 52.35]
                ]]},
    Codes = ambit:shape(GeoJSON, 13),
    lists:foreach(fun(C) ->
        {Lat, Lon} = ambit:decode(C),
        ?assert(is_float(Lat)),
        ?assert(is_float(Lon))
    end, Codes).

%% bounds basic test
bounds_basic_test() ->
    Bounds = {52.3, 4.8, 52.5, 5.1},
    Res = 12,
    Codes = ambit:bounds(Bounds, Res),
    ?assert(length(Codes) > 0),

    %% Codes should be unique
    ?assertEqual(lists:sort(Codes), lists:usort(Codes)),

    %% It should be able to decode the codes.
    lists:foreach(fun(C) ->
                          ?assert(is_binary(C)),
                          {Lat, Lon} = ambit:decode(C),
                          ?assert(is_float(Lat)),
                          ?assert(is_float(Lon))
                  end, Codes).

%% bounds mode test: centroid mode is a subset of corner mode
bounds_mode_test() ->
    Bounds = {52.3, 4.8, 52.5, 5.1},
    Res = 12,
    Corner   = ambit:bounds(Bounds, Res, corner),
    Centroid = ambit:bounds(Bounds, Res, centroid),

    ?assert(length(Corner) >= length(Centroid)),
    ?assert(length(Centroid) > 0),

    %% Every centroid code must appear in the corner results
    lists:foreach(fun(C) ->
        ?assert(lists:member(C, Corner))
    end, Centroid),

    %% In centroid mode, all decoded centroids must strictly fall within bounds
    lists:foreach(fun(C) ->
                          {Lat, Lon} = ambit:decode(C),
                          ?assert(Lat >= 52.3 andalso Lat =< 52.5),
                          ?assert(Lon >= 4.8 andalso Lon =< 5.1)
                  end, Centroid).

%% bounds default mode should match corner mode
bounds_default_mode_test() ->
    Bounds = {52.3, 4.8, 52.5, 5.1},
    Res = 12,
    Default = ambit:bounds(Bounds, Res),
    Corner  = ambit:bounds(Bounds, Res, corner),
    ?assertEqual(Default, Corner).

%% bounds across multiple icosahedral faces
bounds_cross_face_test() ->
    %% Wide bounds crossing face boundaries near equator
    Bounds = {-5.0, -10.0, 15.0, 40.0},
    Codes = ambit:bounds(Bounds, 6),
    ?assert(length(Codes) > 0),
    %% Verify multiple faces are present in the results
    Faces = lists:usort([hd(binary:split(C, <<"-">>)) || C <- Codes]),
    ?assert(length(Faces) > 1),
    ?assertEqual(lists:sort(Codes), lists:usort(Codes)).

%% bounds antimeridian crossing test
bounds_antimeridian_test() ->
    Bounds = {-10.0, 175.0, 10.0, -175.0},
    Codes = ambit:bounds(Bounds, 7),
    ?assert(length(Codes) > 0),
    ?assertEqual(lists:sort(Codes), lists:usort(Codes)).

%% bounds vs shape consistency test for equivalent rectangular polygon
bounds_vs_shape_test() ->
    MinLat = 52.35, MinLon = 4.85, MaxLat = 52.45, MaxLon = 4.95,
    Bounds = {MinLat, MinLon, MaxLat, MaxLon},
    GeoJSON = #{<<"type">> => <<"Polygon">>,
                <<"coordinates">> => [[
                    [MinLon, MinLat], [MaxLon, MinLat], [MaxLon, MaxLat], [MinLon, MaxLat], [MinLon, MinLat]
                ]]},
    Res = 13,
    ShapeCentroid = lists:sort(ambit:shape(GeoJSON, Res, centroid)),
    BoundsCentroid = lists:sort(ambit:bounds(Bounds, Res, centroid)),
    ?assertEqual(ShapeCentroid, BoundsCentroid),
    ShapeCorner = lists:sort(ambit:shape(GeoJSON, Res, corner)),
    BoundsCorner = lists:sort(ambit:bounds(Bounds, Res, corner)),
    %% bounds finds all shape corner codes plus edge-crossing triangles
    lists:foreach(fun(C) ->
        ?assert(lists:member(C, BoundsCorner))
    end, ShapeCorner),
    ?assert(length(BoundsCorner) >= length(ShapeCorner)).

%% bounds badarg validation
bounds_badarg_test() ->
    ?assertError(badarg, ambit:bounds({1, 2, 3}, 10)),
    ?assertError(badarg, ambit:bounds({1, 2, 3, 4}, 0)),
    ?assertError(badarg, ambit:bounds({1, 2, 3, 4}, 25)),
    ?assertError(badarg, ambit:bounds({1, 2, 3, 4}, 10, invalid_mode)).
