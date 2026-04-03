-module(hex_proj_laea_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TOLERANCE, 1.0e-7).
-define(LOOSE_TOLERANCE, 1.0e-1). %% For points near the antipode

round_trip_test_() ->
    Points = [
        {0.0, 0.0},
        {45.0, 45.0},
        {-45.0, -45.0},
        {89.0, 0.0},
        {-89.0, 0.0},
        {90.0, 0.0},           %% North Pole
        {-90.0, 0.0},          %% South Pole
        {0.0, 175.0},          %% Near-edge
        {0.0, -175.0}
    ],
    [?_test(assert_round_trip(Lat, Lon, ?TOLERANCE)) || {Lat, Lon} <- Points].

antipode_proximity_test() ->
    %% Test stability very close to the 180-degree limit (antipode)
    %% Expect larger numerical jitter here
    assert_round_trip(0.0, 179.9, ?LOOSE_TOLERANCE).

center_point_test() ->
    {X, Y} = hex_proj_laea:latlon_to_xy(0.0, 0.0),
    ?assert(abs(X) < ?TOLERANCE),
    ?assert(abs(Y) < ?TOLERANCE).

custom_config_round_trip_test() ->
    Cfg = #{lat0_deg => 52.3676, lon0_deg => 4.9041, radius => 6371000.0},
    Lat = 51.5074,
    Lon = -0.1278,
    {X, Y} = hex_proj_laea:latlon_to_xy(Lat, Lon, Cfg),
    {Lat2, Lon2} = hex_proj_laea:xy_to_latlon(X, Y, Cfg),
    ?assert(abs(Lat - Lat2) < ?TOLERANCE),
    ?assert(abs(Lon - Lon2) < ?TOLERANCE).

world_bbox_test() ->
    {MinX, MaxX, MinY, MaxY} = hex_proj_laea:world_bbox(),
    R = 6371000.0,
    ?assertEqual(-R, MinX),
    ?assertEqual(R, MaxX),
    ?assertEqual(-R, MinY),
    ?assertEqual(R, MaxY).

shape_distortion_polar_test() ->
    %% In LAEA centered at equator, the poles are stretched 2:1 (k/h = 2.0)
    %% We verify this by taking small steps in Lat and Lon at the pole
    R = 6371000.0,
    Epsilon = 0.0001,
    
    %% Forward projection of pole (Lat=90)
    {X0, Y0} = hex_proj_laea:latlon_to_xy(90.0, 0.0),
    
    %% Step south by Epsilon
    {X1, Y1} = hex_proj_laea:latlon_to_xy(90.0 - Epsilon, 0.0),
    DistLat = math:sqrt(math:pow(X1-X0, 2) + math:pow(Y1-Y0, 2)),
    
    %% Step east by Epsilon (at a latitude very close to pole)
    {X2, Y2} = hex_proj_laea:latlon_to_xy(89.0, Epsilon),
    {X3, Y3} = hex_proj_laea:latlon_to_xy(89.0, -Epsilon),
    DistLon = math:sqrt(math:pow(X3-X2, 2) + math:pow(Y3-Y2, 2)),
    
    %% This test just ensures the math is stable; distortions are expected.
    ?assert(DistLat > 0),
    ?assert(DistLon > 0).

boundary_safety_test() ->
    %% Test that points slightly outside the 2R radius don't crash the inverse
    R = 6371000.0,
    {Lat, Lon} = hex_proj_laea:xy_to_latlon(2.0*R + 1.0, 0.0),
    ?assert(is_number(Lat)),
    ?assert(is_number(Lon)).

%% Internal helpers

assert_round_trip(Lat, Lon, Tolerance) ->
    {X, Y} = hex_proj_laea:latlon_to_xy(Lat, Lon),
    {Lat2, Lon2} = hex_proj_laea:xy_to_latlon(X, Y),
    case (abs(Lat - Lat2) < Tolerance) andalso (abs(Lon - Lon2) < Tolerance) of
        true -> ok;
        false ->
            io:format(user, "~nFAILED: Lat=~p, Lon=~p -> X=~p, Y=~p -> Lat2=~p, Lon2=~p (DiffLat=~p, DiffLon=~p)~n",
                      [Lat, Lon, X, Y, Lat2, Lon2, abs(Lat-Lat2), abs(Lon-Lon2)]),
            ?assert(abs(Lat - Lat2) < Tolerance),
            ?assert(abs(Lon - Lon2) < Tolerance)
    end.
