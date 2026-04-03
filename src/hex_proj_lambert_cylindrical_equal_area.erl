
%% Perfectly invertible, no CosLat ambiguity, equal-area so cells 
%% represent equal ground area. The tradeoff is cells are compressed
%% near the poles but that's inevitable for any global projection

-module(hex_proj_lambert_cylindrical_equal_area).

-export([
    latlon_to_xy/2, latlon_to_xy/3,
    xy_to_latlon/2, xy_to_latlon/3
]).

-define(M_PER_DEG_LAT, 111319.49079327357).

latlon_to_xy(Lat, Lon) ->
    {Lon * ?M_PER_DEG_LAT, 
     math:sin(Lat * math:pi() / 180.0) * ?M_PER_DEG_LAT}.

latlon_to_xy(Lat, Lon, _) ->
    latlon_to_xy(Lat, Lon).

xy_to_latlon(X, Y) ->
    {math:asin(Y / ?M_PER_DEG_LAT) * 180.0 / math:pi(),
     X / ?M_PER_DEG_LAT}.

xy_to_latlon(Lat, Lon, _) ->
    xy_to_latlon(Lat, Lon).
