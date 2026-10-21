# The basemap style

`myparty/assets/map/myparty-dark.json` is the map every screen draws on: a
MapLibre style (v8) over OpenFreeMap's OpenMapTiles-schema vector tiles,
rendered on the device by `vector_map_tiles`. It is bundled with the app, so
there is nothing to host; only the tiles come from the network. Loading,
caching, retry and attribution live in `myparty/lib/ui/widgets/basemap.dart`.

## What it is for

The party pins are the subject; the basemap is the backdrop that tells you
which street they are on. Every choice below follows from that.

| Element | Colour | Notes |
|---|---|---|
| Land (background) | `#171827` | Deep navy, not black. `kBasemapBackground` must equal it (a test checks). |
| Residential | `#191a2b` | Barely there; breaks up the land at low zoom. |
| Parks, wood, grass | `#16231f` | Dark, low-opacity green. |
| Water | `#0f2b35` | Muted blue-teal, clearly not land. |
| Buildings (z14+) | `#1f2333`, edge `#262a3b` | Footprints for orientation, faded in from z14. |
| Minor roads | `#2f323f` | Lighter than land at every zoom; from z12. |
| Secondary/tertiary | `#3f4353` | |
| Primary/trunk | `#4e5265` | |
| Motorway | `#5b6076` | Brightest and widest. |
| Street/area labels | `#b8bccc` / `#c6c9d6`, halo `#12131f` 1.6px | Major names from z13, minor from z16. |
| Neighbourhoods | `#9ea3b6`, uppercase | z12–17. |
| Sea/bay names | `#6f9bab`, italic | Seas, bays and straits only — no ponds or fountains. |

Deliberately absent: points of interest, house numbers, road shields, airport
icons, and the sprite sheet altogether. **No purple, pink or red** anywhere in
the style: purple is a public pin, red is a private one (`AppColors.private`),
and `basemap_test.dart` fails on any saturated colour with a hue in 255°–345°.

## Editing it in Maputnik

1. Open <https://maplibre.org/maputnik/> → **Open** → **Upload** →
   `myparty/assets/map/myparty-dark.json`. It loads the real OpenFreeMap tiles
   through the style's own `sources` entry; no key is needed.
2. Edit. Centre on Athens (the style's `center` is Syntagma) and check zooms
   10, 13, 15 (where the app opens), 16 and 17.
3. **Export** → **Download** and replace the file. Keep the 2-space JSON
   formatting so the diff stays reviewable.
4. Run `flutter test test/basemap_test.dart` from `myparty/`. There is no
   version to bump: the loader fingerprints the file's contents, so the
   30-day disk cache of rendered tiles can never serve the old look.

Maputnik renders with MapLibre GL, which supports more of the style spec than
the on-device renderer (`vector_tile_renderer` 6.1). What looks right in
Maputnik can still be dropped on the phone, so stay inside this subset:

- Layer types `background`, `fill`, `line`, `symbol` (and `raster`,
  `fill-extrusion`, unused here). Nothing else is drawn.
- Expressions: `get`, `has`, `==`/`!=`/`<`/`>`…, `all`, `any`, `!`, `in`,
  `match`, `case`, `coalesce`, `concat`, `interpolate` (linear, exponential,
  cubic-bezier), `step`, `zoom`, `geometry-type`, `to-string`/`to-number`,
  arithmetic. **Not** `literal`, `format`, `number-format`, `within`.
- Text: `text-field`, `text-size`, `text-font` (only the first entry, and only
  "Italic" in its name has an effect — everything else falls back to the
  system font), `text-transform`, `text-letter-spacing`, `text-max-width`,
  `text-anchor`, `text-justify`, `text-halo-*`, `symbol-placement: line`.
  **Not** `text-variable-anchor`, `text-offset`, `symbol-spacing`,
  `text-halo-blur`.

`basemap_test.dart` fails if the renderer warns about anything in the file or
drops a layer, so an unsupported addition is a red test rather than a layer
that silently never draws.

Labels use OSM's `name` (Greek in Athens, matching the addresses MapTiler
returns), falling back to `name_en`. `name:latin` is in the tiles if that
changes — see `docs/backlog.md` 1.47.

## Changing where it comes from

- **A hosted style instead of the bundled one:** set `kBasemapStyle` in
  `basemap.dart` to its `https://` URL. It is then read with
  `vector_map_tiles`' `StyleReader`, sprites included. Hosting anywhere static
  works (Firebase Hosting, GitHub Pages, a Supabase Storage public bucket);
  serve it with `Content-Type: application/json`. The bundled file is
  recommended: it ships and versions with the app and cannot be down.
- **Different tiles:** change `sources.openmaptiles.url` in the style. Any
  server speaking the OpenMapTiles schema with a TileJSON works unchanged —
  self-hosted OpenMapTiles/Planetiler output on Cloudflare R2 is the planned
  fallback if OpenFreeMap becomes unreliable (`docs/backlog.md` 1.46).
  Protomaps' own basemap uses a **different schema** (`roads`, `earth`, …), so
  moving to it means rewriting the layers, not just the URL.
- **Attribution** follows the tiles: OpenFreeMap, OpenMapTiles and
  OpenStreetMap today (`MpBasemapAttribution`, `kBasemapCreditShort`).
