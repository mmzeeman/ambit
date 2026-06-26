
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
    Corners = ambit:cell_geometry(Code),
    ?assertEqual(3, length(Corners)),
    lists:foreach(fun({Lat, Lon}) ->
        ?assert(is_float(Lat)),
        ?assert(is_float(Lon))
    end, Corners).

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

parent_root_test() ->
    ?assertEqual(<<"0-000">>, ambit:parent(<<"0-0000">>)),
    ?assertEqual(<<"0-00">>, ambit:parent(<<"0-000">>)),
    ?assertEqual(<<"0-0">>, ambit:parent(<<"0-00">>)),
    ?assertEqual(<<"0-">>, ambit:parent(<<"0-0">>)),
    ?assertEqual(<<"0-">>, ambit:parent(<<"0-">>)),
    ok.

% Test: Empty list returns empty ranges
empty_list_test() ->
    {ranges, Ranges} = ambit:codes_to_ranges([]),
    ?assertEqual([], Ranges).

% Test: Single code returns as-is
single_code_test() ->
    Code = <<"0-0">>,
    {ranges, Ranges} = ambit:codes_to_ranges([Code]),
    ?assertEqual([{prefix, Code}], Ranges).

% Test: All 4 children collapse to parent
collapse_four_children_test() ->
    Parent = <<"0-01">>,
    Children = [<<"0-010">>, <<"0-011">>, <<"0-012">>, <<"0-013">>],
    {ranges, Ranges} = ambit:codes_to_ranges(Children),
    ?assertEqual([{prefix, Parent}], Ranges).

% Test: Three children do NOT collapse
partial_children_test() ->
    Codes = [<<"0-010">>, <<"0-011">>, <<"0-012">>],
    {ranges, Ranges} = ambit:codes_to_ranges(Codes),
    SortedCodes = lists:sort(Codes),
    Expected = [{prefix, Code} || Code <- SortedCodes],
    ?assertEqual(Expected, Ranges).

% Test: Unsorted input gets sorted correctly
unsorted_input_test() ->
    Codes = [<<"0-012">>, <<"0-010">>, <<"0-013">>, <<"0-011">>],
    {ranges, Ranges} = ambit:codes_to_ranges(Codes),
    ?assertEqual([{prefix, <<"0-01">>}], Ranges).

% Test: Multi-level collapse (grandchildren → children → parent)
multilevel_collapse_test() ->
    %% 16 children at level 3 that collapse to 4 at level 2, then to 1 at level 1
    Level3Codes = [
        <<"0-0100">>, <<"0-0101">>, <<"0-0102">>, <<"0-0103">>,
        <<"0-0110">>, <<"0-0111">>, <<"0-0112">>, <<"0-0113">>,
        <<"0-0120">>, <<"0-0121">>, <<"0-0122">>, <<"0-0123">>,
        <<"0-0130">>, <<"0-0131">>, <<"0-0132">>, <<"0-0133">>
    ],
    {ranges, Ranges} = ambit:codes_to_ranges(Level3Codes),
    ?assertEqual([{prefix, <<"0-01">>}], Ranges).

% Test: Partial multi-level (only 3 of 4 level-2 children)
partial_multilevel_test() ->
    %% 12 codes = 3 complete sets of 4 at level 3, plus 1 more
    Codes = [
        %% First complete set (level 3): 0-0100-0103
        <<"0-0100">>, <<"0-0101">>, <<"0-0102">>, <<"0-0103">>,
        %% Second complete set (level 3): 0-0110-0113
        <<"0-0110">>, <<"0-0111">>, <<"0-0112">>, <<"0-0113">>,
        %% Third complete set (level 3): 0-0120-0123
        <<"0-0120">>, <<"0-0121">>, <<"0-0122">>, <<"0-0123">>,
        %% Partial set (only 1 from 0-013x)
        <<"0-0130">>
    ],
    {ranges, Ranges} = ambit:codes_to_ranges(Codes),
    %% Should collapse to: 0-010, 0-011, 0-012, and one 0-0130
    Expected = [
        {prefix, <<"0-010">>},
        {prefix, <<"0-011">>},
        {prefix, <<"0-012">>},
        {prefix, <<"0-0130">>}
    ],
    ?assertEqual(Expected, Ranges).

% Test: Mixed different faces
mixed_faces_test() ->
    Codes = [
        <<"0-01">>, <<"0-02">>, <<"0-03">>,
        <<"1-010">>, <<"1-011">>, <<"1-012">>, <<"1-013">>
    ],
    {ranges, Ranges} = ambit:codes_to_ranges(Codes),
    Expected = [
        {prefix, <<"0-01">>},
        {prefix, <<"0-02">>},
        {prefix, <<"0-03">>},
        {prefix, <<"1-01">>}
    ],
    ?assertEqual(Expected, Ranges).

% Test: Already collapsed code stays as-is
already_collapsed_test() ->
    Code = <<"0-">>,
    {ranges, Ranges} = ambit:codes_to_ranges([Code]),
    ?assertEqual([{prefix, Code}], Ranges).

% Test: Large dataset with multiple collapse opportunities
large_dataset_test() ->
    %% Create 8 complete sets at level 2, spread across 2 faces
    Face0Codes = [
        <<"0-000">>, <<"0-001">>, <<"0-002">>, <<"0-003">>,
        <<"0-010">>, <<"0-011">>, <<"0-012">>, <<"0-013">>,
        <<"0-020">>, <<"0-021">>, <<"0-022">>, <<"0-023">>,
        <<"0-030">>, <<"0-031">>, <<"0-032">>, <<"0-033">>
    ],
    Face1Codes = [
        <<"1-000">>, <<"1-001">>, <<"1-002">>, <<"1-003">>,
        <<"1-010">>, <<"1-011">>, <<"1-012">>, <<"1-013">>,
        <<"1-020">>, <<"1-021">>, <<"1-022">>, <<"1-023">>,
        <<"1-030">>, <<"1-031">>, <<"1-032">>, <<"1-033">>
    ],
    AllCodes = Face0Codes ++ Face1Codes,
    {ranges, Ranges} = ambit:codes_to_ranges(AllCodes),
    %% Should collapse to just two: 0-0 and 1-0
    Expected = [{prefix, <<"0-0">>}, {prefix, <<"1-0">>}],
    ?assertEqual(Expected, Ranges).

% Test: codes_to_sql generates correct SQL
sql_generation_test() ->
    Codes = [<<"0-010">>, <<"0-011">>, <<"0-012">>, <<"0-013">>, <<"1-01">>],
    SqlQuery = ambit:codes_to_sql(Codes),
    %% Should have collapsed to 0-01 and 1-01
    ?assertMatch(_ when is_list(SqlQuery), SqlQuery),
    ?assert(string:find(SqlQuery, "code LIKE") =/= nomatch),
    ?assert(string:find(SqlQuery, "0-01") =/= nomatch),
    ?assert(string:find(SqlQuery, "1-01") =/= nomatch).

% Test: codes_to_sql with single code
sql_single_code_test() ->
    Codes = [<<"0-01">>],
    SqlQuery = ambit:codes_to_sql(Codes),
    Expected = "code LIKE '0-01%'",
    ?assertEqual(Expected, SqlQuery).

% Test: codes_to_sql with empty list
sql_empty_list_test() ->
    Codes = [],
    SqlQuery = ambit:codes_to_sql(Codes),
    ?assertEqual("false", SqlQuery).

% Test: Interleaved codes from different parents
interleaved_codes_test() ->
    Codes = [
        <<"0-000">>, <<"0-001">>, <<"0-002">>, <<"0-003">>,
        <<"0-100">>, <<"0-101">>, <<"0-102">>, <<"0-103">>,
        <<"0-200">>, <<"0-201">>, <<"0-202">>, <<"0-203">>,
        <<"0-300">>, <<"0-301">>, <<"0-302">>, <<"0-303">>
    ],
    {ranges, Ranges} = ambit:codes_to_ranges(Codes),
    Expected = [
        {prefix, <<"0-00">>},
        {prefix, <<"0-10">>},
        {prefix, <<"0-20">>},
        {prefix, <<"0-30">>}
    ],
    ?assertEqual(Expected, Ranges).

% Test: Three complete + one partial at same level
three_plus_one_test() ->
    Codes = [
        <<"0-000">>, <<"0-001">>, <<"0-002">>, <<"0-003">>,
        <<"0-010">>, <<"0-011">>, <<"0-012">>, <<"0-013">>,
        <<"0-020">>, <<"0-021">>, <<"0-022">>, <<"0-023">>,
        <<"0-030">>, <<"0-031">>  %% Only 2 of 4 children
    ],
    {ranges, Ranges} = ambit:codes_to_ranges(Codes),
    Expected = [
        {prefix, <<"0-00">>},
        {prefix, <<"0-01">>},
        {prefix, <<"0-02">>},
        {prefix, <<"0-030">>},
        {prefix, <<"0-031">>}
    ],
    ?assertEqual(Expected, Ranges).

% Test: Root level codes (no children)
root_codes_test() ->
    Codes = [<<"0-">>, <<"1-">>, <<"2-">>],
    {ranges, Ranges} = ambit:codes_to_ranges(Codes),
    Expected = [{prefix, <<"0-">>}, {prefix, <<"1-">>}, {prefix, <<"2-">>}],
    ?assertEqual(Expected, Ranges).

% Test: Very deep nesting all present
deep_nesting_test() ->
    %% Create a chain: one code at each level that has all 4 children
    Base = <<"0-">>,
    Level1 = <<"0-0">>,
    Level2 = <<"0-00">>,
    Level3 = <<"0-000">>,
    Level4 = <<"0-0000">>,
    Level5 = <<"0-00000">>,
    
    %% All 4 children at each level
    Level1Codes = [<<"0-0">>, <<"0-1">>, <<"0-2">>, <<"0-3">>],
    Level2Codes = [<<"0-00">>, <<"0-01">>, <<"0-02">>, <<"0-03">>],
    Level3Codes = [<<"0-000">>, <<"0-001">>, <<"0-002">>, <<"0-003">>],
    Level4Codes = [<<"0-0000">>, <<"0-0001">>, <<"0-0002">>, <<"0-0003">>],
    Level5Codes = [<<"0-00000">>, <<"0-00001">>, <<"0-00002">>, <<"0-00003">>],
    
    AllCodes = Level1Codes ++ Level2Codes ++ Level3Codes ++ Level4Codes ++ Level5Codes,
    {ranges, Ranges} = ambit:codes_to_ranges(AllCodes),

    %% Should collapse all the way to root
    ?assertEqual([{prefix, <<"0-">>}], Ranges).
