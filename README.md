# Hexveil: Icosahedral Gnomonic Aperture 4 Hexagons

Hexveil is a high-performance Erlang implementation of a hierarchical discrete global
grid system (DGGS). It uses an **Aperture 4** hierarchy mapped onto the 20 faces of
an **icosahedron** using a **gnomonic projection**.

## What is Hexveil?

Hexveil divides the Earth's surface into a hierarchy of hexagonal cells. Unlike
traditional Lat/Lon coordinates, which vary in physical distance depending on latitude,
Hexveil provides a mathematically stable way to index and search spatial data.

### Key Characteristics:
*   **Aperture 4:** Each parent cell is divided into 4 smaller child cells in the next
    resolution. This provides a smooth, consistent scaling factor of 2.0x in edge length
    per level.
*   **Icosahedral Projection:** By using 20 triangular faces to represent the sphere,
    Hexveil minimizes the "map distortion" found in equirectangular projections (like
    standard Web Mercator).
*   **Gnomonic Mapping:** Central projection from the Earth's center to the face planes
    ensures that great circles are represented as straight lines, making navigation and
    neighbor-finding computationally efficient.
*   **Base-4 Encoding:** Cell IDs are represented as `Face-Digits` (e.g., `0-213123...`),
    where the face is base-20 (0-9, a-j) and the digits represent the hierarchical path.

---

## Visualizing the Grid

Hexveil provides a visualization tool (`hexveil_viz.escript`) that generates an interactive
Leaflet map to inspect the grid.

### 1. The Global Structure (Faces)
The Earth is first divided into 20 icosahedral faces. Each face acts as its own local
coordinate system, significantly reducing distortion at the poles.

![Icosahedral Face Mapping](https://raw.githubusercontent.com/mmzeeman/hexveil/main/docs/faces.png)
*(Placeholder: Image showing the 20 icosahedral faces mapped to the globe)*

### 2. Hierarchical Scaling (Aperture 4)
As you increase the resolution, each hexagon precisely covers the center of its parent, with
three other children surrounding it.

![Aperture 4 Hierarchy](https://raw.githubusercontent.com/mmzeeman/hexveil/main/docs/hierarchy.png)
*(Placeholder: Image showing L17 cells nested within L16 and L15 parents)*

---

## Resolution Table

| Level | Approx. Diameter | Typical Use Case |
| :--- | :--- | :--- |
| **24** | ~2.5 m | High-precision / Human-scale tracking |
| **18** | ~160 m | Privacy-preserving proximity (Level 1) |
| **17** | ~320 m | Neighborhood-scale indexing |
| **9** | ~80 km | Regional / Meteorological data |
| **1** | ~20,000 km | Global / Continental scale |

---

## Usage

### Encoding a Coordinate
```erlang
% Encode Amsterdam (Lat: 52.3676, Lon: 4.9041) at Level 17
Code = hexveil:encode({52.3676, 4.9041}, 17).
% Result: <<"0-21312323330031321">>
```

### Finding Neighbors
```erlang
% Get the 6 immediate neighbors of a cell
Neighbors = hexveil:neighbors(Code).
```

### Generating the Visualization
Run the provided escript to generate `hexveil_viz.html`:
```bash
./hexveil_viz.escript 52.3676 4.9041 15
```
This will create a map showing the target cell and its surrounding neighborhood across
three resolution levels.

---

## Privacy Applications

Hexveil is designed with privacy in mind. Because it is hierarchical, you can easily
"coarsen" a user's location by simply stripping digits from the end of their Cell ID.

To prevent global tracking, we recommend **Salted HMAC Hashing**:
1. Take a user's Cell ID (e.g., `0-213123...`).
2. Add a secret server-side pepper and the User's ID.
3. Store the hash: `HMAC_SHA256(Secret, UserID + CellID)`.

This ensures that even if your database is compromised, the physical locations cannot
be recovered without the secret key.

---

## License
Apache 2.0
