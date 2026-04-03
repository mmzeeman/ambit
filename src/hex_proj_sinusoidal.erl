%% hex_proj_sinusoidal.erl
%%
%% Sinusoidal equal-area projection:
%% - Global
%% - Equal-area
%% - Simple, invertible
%% - Good as a first global projection for a hex grid
%%
%% Expected config map:
%%   #{ lon0_deg => float(),  %% central meridian in degrees (default 0.0)
%%      radius   => float()   %% scale (default 1.0)
%%    }.

-module(hex_proj_sinusoidal).
%-behaviour(hex_proj_behaviour).

-export([
    latlon_to_xy/2, latlon_to_xy/3,
    xy_to_latlon/2, xy_to_latlon/3
]).

%% Types (for dialyzer friendliness)
-type proj_cfg() :: #{
    lon0_deg => float(),
    radius   => float()
}.

-define(DEFAULT_CFG, #{ lon0_deg => 0.0, radius => 6371000.0 }).

latlon_to_xy(LatDeg, LonDeg) -> latlon_to_xy(LatDeg, LonDeg, ?DEFAULT_CFG).
xy_to_latlon(X, Y) -> xy_to_latlon(X, Y, ?DEFAULT_CFG).

-spec latlon_to_xy(float(), float(), proj_cfg()) -> {float(), float()}.
latlon_to_xy(LatDeg, LonDeg, #{ lon0_deg := Lon0Deg, radius := R }) ->
    Lat = deg2rad(LatDeg),
    Lon = deg2rad(LonDeg),
    Lon0 = deg2rad(Lon0Deg),
    CosLat = math:cos(Lat),
    X = R * (Lon - Lon0) * CosLat,
    Y = R * Lat,
    {X, Y}.

-spec xy_to_latlon(float(), float(), proj_cfg()) -> {float(), float()}.
xy_to_latlon(X, Y, #{ lon0_deg := Lon0Deg, radius := R }) ->
    Lon0 = deg2rad(Lon0Deg),
    Lat = Y / R,
    CosLat = math:cos(Lat),

    %% Guard against CosLat ~ 0 at the poles; clamp slightly
    SafeCosLat =
        %% Very close to poles: clamp to tiny value to avoid div-by-zero.
        %% This will slightly blow up longitude near +/-90°, but that's
        %% unavoidable for sinusoidal; those regions are degenerate anyway.
        case CosLat of
            +0.0 ->
                1.0e-12;
            -0.0 ->
                1.0e-12;
            _ ->
                CosLat
        end,

    Lon = Lon0 + X / (R * SafeCosLat),

    LatDeg = rad2deg(Lat),
    LonDeg = rad2deg(Lon),

    {LatDeg, LonDeg}.

%% ================
%% Internal helpers
%% ================

deg2rad(D) ->
    D * 0.017453292519943295. % math:pi() / 180.0.

rad2deg(R) ->
    R * 57.29577951308232. % 180.0 / math:pi().
