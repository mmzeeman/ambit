%%--------------------------------------------------------------------
%% hex_proj_laea.erl
%%
%% Lambert Azimuthal Equal Area (LAEA) projection, forward and inverse.
%%
%% https://en.wikipedia.org/wiki/Lambert_azimuthal_equal-area_projection
%%
%% Pure Erlang, safe for global use.
%%
%% Expected config map:
%%   #{
%%      lat0_deg => float(),   %% center latitude
%%      lon0_deg => float(),   %% center longitude
%%      radius   => float()    %% Earth radius in meters
%%   }.
%%
%% Recommended:
%%   #{lat0_deg => 0.0, lon0_deg => 0.0, radius => 6371000.0}
%%
%% This projection is *excellent* for drawing hex polygons globally,
%% because reverse mapping is stable at all scales (unlike sinusoidal).
%%
%% Implements:
%%   latlon_to_xy/3  % forward
%%   xy_to_latlon/3  % inverse
%%
%% Integration:
%%   Use with hex_grid:xy_to_hex and hex_grid:hex_to_xy
%%   in your hex_global:latlon_to_hex and hex_global:hex_to_latlon.
%%
%%--------------------------------------------------------------------

-module(hex_proj_laea).

-export([latlon_to_xy/2, xy_to_latlon/2]).
-export([latlon_to_xy/3, xy_to_latlon/3]).
-export([world_bbox/0]).

%%--------------------------------------------------------------------
%% Forward projection: (lat,lon) → (X,Y)
%%
%% Formulas follow Snyder (equal-area azimuthal):
%%
%%  k  = sqrt( 2 / (1 + sin(lat0)*sin(lat) + cos(lat0)*cos(lat)*cos(dlon)) )
%%  X  = R * k * cos(lat) * sin(dlon)
%%  Y  = R * k * ( cos(lat0)*sin(lat) - sin(lat0)*cos(lat)*cos(dlon) )
%%
%%--------------------------------------------------------------------

-define(DEFAULT_RADIUS, 6371000.0).
-define(DEFAULT_CFG, #{ lat0_deg => 0.0,
                        lon0_deg => 0.0,
                        radius => ?DEFAULT_RADIUS }).

latlon_to_xy(LatDeg, LonDeg) -> latlon_to_xy(LatDeg, LonDeg, ?DEFAULT_CFG).
xy_to_latlon(X, Y) -> xy_to_latlon(X, Y, ?DEFAULT_CFG).

-spec latlon_to_xy(float(), float(), map()) -> {float(), float()}.
latlon_to_xy(LatDeg, LonDeg, #{ lat0_deg := Lat0Deg, lon0_deg := Lon0Deg, radius := R }) ->
    Lat  = deg2rad(LatDeg),
    Lon  = deg2rad(LonDeg),
    Lat0 = deg2rad(Lat0Deg),
    Lon0 = deg2rad(Lon0Deg),

    Dlon = Lon - Lon0,
    SinLat = math:sin(Lat),
    CosLat = math:cos(Lat),
    SinLat0 = math:sin(Lat0),
    CosLat0 = math:cos(Lat0),

    Den = 1.0 + SinLat0*SinLat + CosLat0*CosLat*math:cos(Dlon),
    %% Avoid NaN near antipode
    SafeDen = case Den of
                  +0.0 -> 1.0e-15;
                  -0.0 -> 1.0e-15;
                  _   -> Den
              end,

    K = math:sqrt(2.0 / SafeDen),

    X = R * K * CosLat * math:sin(Dlon),
    Y = R * K * (CosLat0*SinLat - SinLat0*CosLat*math:cos(Dlon)),

    {X, Y}.

%%--------------------------------------------------------------------
%% Inverse projection: (X,Y) → (lat,lon)
%%
%% Reverse Snyder formulas:
%%
%%  p   = sqrt(X² + Y²)
%%  c   = 2 * asin( p / (2R) )
%%  lat = asin( cos(c)*sin(lat0) + (Y*sin(c)*cos(lat0))/p )
%%  lon = lon0 + atan2( X*sin(c),
%%                      p*cos(lat0)*cos(c) - Y*sin(lat0)*sin(c) )
%%
%% Special case: p == 0 → center point
%%
%%--------------------------------------------------------------------

xy_to_latlon(X, Y, #{ lat0_deg := Lat0Deg, lon0_deg := Lon0Deg, radius := R }) ->
    Lat0 = deg2rad(Lat0Deg),
    Lon0 = deg2rad(Lon0Deg),
    SinLat0 = math:sin(Lat0),
    CosLat0 = math:cos(Lat0),

    P = math:sqrt(X*X + Y*Y),

    case P of
        %% At projection center: lat=lat0, lon=lon0
        +0.0 -> {Lat0Deg, Lon0Deg};
        -0.0 -> {Lat0Deg, Lon0Deg};
        _ ->
            %% Clamp to [-1, 1] for asin safety, though P/(2R) should be <= 1
            Ratio = P / (2.0 * R),
            SafeRatio = if Ratio > 1.0 -> 1.0; true -> Ratio end,
            C = 2.0 * math:asin(SafeRatio),
            SinC = math:sin(C),
            CosC = math:cos(C),

            Lat = math:asin(
                    CosC*SinLat0
                    + (Y * SinC * CosLat0) / P
                  ),

            Lon = Lon0 + math:atan2(
                           X * SinC,
                           P * CosLat0 * CosC - Y * SinLat0 * SinC
                       ),

            {rad2deg(Lat), rad2deg(Lon)}
    end.

world_bbox() ->
    R = ?DEFAULT_RADIUS,
    {-R, R, -R, R}.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

deg2rad(D) -> D * math:pi() / 180.0.
rad2deg(R) -> R * 180.0 / math:pi().

