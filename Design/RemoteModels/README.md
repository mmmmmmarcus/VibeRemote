# Siri Remote CAD sources

| Original supplied file | Settings model |
| --- | --- |
| `Apple_TV_4K_Remote.step` | First-generation black-glass Siri Remote (9 solids) |
| `Siri Remote 2021.step` | Second- and third-generation aluminum Siri Remote (45 solids) |

These are the user's original files, copied byte for byte. They replace the initial
procedural approximation. Source metadata and CAD face colors are retained.

To regenerate with the installed FreeCAD 0.21.1 Python runtime:

```sh
/Applications/FreeCAD.app/Contents/Resources/bin/python scripts/convert_remote_models.py
```

For another installation, use its Python and set `FREECAD_LIB` to its module directory.
FreeCAD is not needed to build/run the app: generated COLLADA meshes and JSON manifests
are checked into `Resources/RemoteModels` and included in the SwiftPM resource bundle.

Conversion preserves all solids, assembly placements, faces, and colors. Linear
meshing tolerance is 0.06 mm and angular tolerance is 0.20 radians. Analytic surface
normals retain smooth curvature without smoothing across CAD face boundaries. Use
Open CASCADE's optimal bounding box: the ordinary spline control-hull bounds can
substantially overestimate trimmed faces. Center, rotate the first model from X-front
to Z-front, and uniformly scale the model to a 394-unit body in the 398-point guide.
JSON records the exact source hash, transform, scale, mesh counts and part coordinates.

The old CAD lacks printed button symbols. Settings adds ink planes over its imported
button faces; the aluminum CAD already supplies its own symbols. Lighting, finish
parameters and the small resting rotation are presentation settings, not CAD edits.

Keep both models together and retain generation-specific callouts. After regenerating,
run `swift test`, render both models / appearances, and verify the installed bundle
with `VIBEREMOTE_VERIFY_APP=/Applications/VibeRemote.app swift test`.
