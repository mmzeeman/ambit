%% But that distorts cells near the poles.

-module(hex_proj_equirectangular).

-export([
    latlon_to_xy/2, latlon_to_xy/3,
    xy_to_latlon/2, xy_to_latlon/3
]).

-define(M_PER_DEG_LAT, 111319.49079327357).

latlon_to_xy(Lat, Lon) ->
    {Lon * ?M_PER_DEG_LAT, Lat * ?M_PER_DEG_LAT}.

latlon_to_xy(Lat, Lon, _) ->
    latlon_to_xy(Lat, Lon).

xy_to_latlon(X, Y) ->
    {Y / ?M_PER_DEG_LAT, X / ?M_PER_DEG_LAT}.

xy_to_latlon(Lat, Lon, _) ->
    xy_to_latlon(Lat, Lon).
