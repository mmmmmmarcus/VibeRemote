#!/usr/bin/env python3
"""Rebuild bundled display meshes from the user-supplied STEP originals.

/Applications/FreeCAD.app/Contents/Resources/bin/python scripts/convert_remote_models.py
Requires FreeCAD's Python modules only at asset-generation time; never at app runtime.
No shape approximation or boolean edits: tessellate every CAD face, preserving colors,
solids and assembly placement. Only a rigid axis transform and uniform scale are applied.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.environ.get('FREECAD_LIB', '/Applications/FreeCAD.app/Contents/Resources/lib'))
import FreeCAD
import Part
import MeshPart

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'Resources/RemoteModels'
LINEAR = 0.06  # mm, before uniform display scaling
ANGULAR = 0.20  # radians; analytic surface normals preserve smooth curvature
NAMESPACE = 'http://www.collada.org/2005/11/COLLADASchema'
ET.register_namespace('', NAMESPACE)


def tag(parent, name, attributes=None, text=None):
    child = ET.SubElement(parent, '{' + NAMESPACE + '}' + name, attributes or {})
    if text is not None:
        child.text = text
    return child


def refs(value):
    return [int(v) for v in re.findall(r'#(\d+)', value)]


def decode_name(value):
    return re.sub(r'\\X2\\(.*?)\\X0\\', lambda m: bytes.fromhex(m[1]).decode('utf-16-be'), value)


def styles(text):
    entities = {int(n): value for n, value in re.findall(r'#(\d+)\s*=\s*(.*?);', text, re.S)}
    colors = {}
    for key, value in entities.items():
        match = re.fullmatch(r"COLOUR_RGB\('([^']*)',\s*([^,]+),\s*([^,]+),\s*([^\)]+)\)", value.strip())
        if match:
            colors[key] = (decode_name(match[1]), tuple(float(match[i]) for i in [2, 3, 4]))
    def color(key, seen=None):
        seen = set() if seen is None else seen
        if key in colors:
            return key
        if key in seen:
            return None
        seen.add(key)
        for ref in refs(entities[key]):
            result = color(ref, seen)
            if result is not None:
                return result
        return None
    assigned = {}
    solids = []
    for key, value in entities.items():
        if value.startswith('STYLED_ITEM('):
            ids = refs(value)
            found = color(ids[0])
            if found is not None:
                assigned[ids[-1]] = found
        if value.startswith('MANIFOLD_SOLID_BREP('):
            name = decode_name(re.search(r"\('([^']*)'", value)[1])
            solids.append((key, name, refs(entities[refs(value)[0]])))
    return colors, assigned, solids


def build(filename, output, old):
    source = ROOT / 'Design/RemoteModels' / filename
    shape = Part.read(str(source))
    colors, assigned, records = styles(source.read_text())
    assert len(records) == len(shape.Solids)
    bounds = shape.optimalBoundingBox()
    center = bounds.Center
    scale = 394.0 / bounds.YLength
    def point(p):
        p = p - center
        return ((-p.z, p.y, p.x) if old else (p.x, p.y, p.z))
    def vector(v):
        return (-v.z, v.y, v.x) if old else (v.x, v.y, v.z)
    def fmt(values):
        return ' '.join(f'{v:.6f}' for v in values)

    doc = ET.Element('{' + NAMESPACE + '}COLLADA', {'version': '1.4.1'})
    asset = tag(doc, 'asset')
    tag(asset, 'contributor')
    tag(asset, 'created', text='2026-10-12T00:00:00Z')
    tag(asset, 'modified', text='2026-10-12T00:00:00Z')
    tag(asset, 'unit', {'name': 'display-unit', 'meter': '1'})
    tag(asset, 'up_axis', text='Y_UP')
    effects = tag(doc, 'library_effects')
    materials = tag(doc, 'library_materials')
    for key, (name, rgb) in colors.items():
        effect = tag(effects, 'effect', {'id': f'fx{key}'})
        profile = tag(effect, 'profile_COMMON')
        technique = tag(profile, 'technique', {'sid': 'common'})
        phong = tag(technique, 'phong')
        tag(tag(phong, 'diffuse'), 'color', text=fmt((*rgb, 1)))
        tag(tag(phong, 'specular'), 'color', text='0.25 0.25 0.25 1')
        tag(tag(phong, 'shininess'), 'float', text='30')
        material = tag(materials, 'material', {'id': f'm{key}', 'name': name})
        tag(material, 'instance_effect', {'url': f'#fx{key}'})
    geometries = tag(doc, 'library_geometries')
    visual = tag(tag(doc, 'library_visual_scenes'), 'visual_scene', {'id': 'CADScene'})
    root = tag(visual, 'node', {'id': 'cad', 'name': 'cad'})
    solid_names = ({0:'back-ring', 1:'back', 2:'tv', 3:'siri', 4:'playPause', 5:'volume', 6:'body', 7:'inner-shell', 8:'glass-face'} if old else
                   {9:'body', 16:'power', 20:'siri', 26:'clickpad-center', 30:'clickpad-ring', 14:'mute', 32:'volume', 37:'back', 38:'playPause', 42:'tv'})
    report = []
    total_triangles = 0
    for index, (solid, (step_id, label, face_ids)) in enumerate(zip(shape.Solids, records)):
        assert len(face_ids) == len(solid.Faces), (index, len(face_ids), len(solid.Faces))
        positions, normals, groups = [], [], {}
        for face, face_id in zip(solid.Faces, face_ids):
            mesh = MeshPart.meshFromShape(Shape=face, LinearDeflection=LINEAR, AngularDeflection=ANGULAR, Relative=False)
            points, triangles = mesh.Topology
            offset = len(positions) // 3
            color_id = assigned.get(face_id, assigned.get(step_id, next(iter(colors))))
            indices = groups.setdefault(color_id, [])
            for p in points:
                positions.extend(v * scale for v in point(p))
                u, v = face.Surface.parameter(p)
                n = face.normalAt(u, v)
                normals.extend(vector(n))
            for triangle in triangles:
                indices.extend(offset + i for i in triangle)
        geometry_id = f'solid{index}'
        geometry = tag(geometries, 'geometry', {'id': geometry_id, 'name': label})
        mesh_xml = tag(geometry, 'mesh')
        for suffix, values in [('positions', positions), ('normals', normals)]:
            src_id = f'{geometry_id}-{suffix}'
            src = tag(mesh_xml, 'source', {'id': src_id})
            tag(src, 'float_array', {'id': src_id + '-data', 'count': str(len(values))}, fmt(values))
            accessor = tag(tag(src, 'technique_common'), 'accessor', {'source': '#' + src_id + '-data', 'count': str(len(values)//3), 'stride': '3'})
            for axis in ['X', 'Y', 'Z']:
                tag(accessor, 'param', {'name': axis, 'type': 'float'})
        vertices = tag(mesh_xml, 'vertices', {'id': geometry_id + '-vertices'})
        tag(vertices, 'input', {'semantic': 'POSITION', 'source': '#' + geometry_id + '-positions'})
        count = 0
        for color_id, indices in groups.items():
            triangles_xml = tag(mesh_xml, 'triangles', {'count': str(len(indices)//3), 'material': f'm{color_id}'})
            tag(triangles_xml, 'input', {'semantic': 'VERTEX', 'source': '#' + geometry_id + '-vertices', 'offset': '0'})
            tag(triangles_xml, 'input', {'semantic': 'NORMAL', 'source': '#' + geometry_id + '-normals', 'offset': '0'})
            tag(triangles_xml, 'p', text=' '.join(map(str, indices)))
            count += len(indices)//3
        node = tag(root, 'node', {'id': f'node{index}', 'name': solid_names.get(index, f'cad-part-{index}')})
        instance = tag(node, 'instance_geometry', {'url': '#' + geometry_id})
        binding = tag(tag(instance, 'bind_material'), 'technique_common')
        for color_id in groups:
            tag(binding, 'instance_material', {'symbol': f'm{color_id}', 'target': f'#m{color_id}'})
        bb = solid.optimalBoundingBox()
        p = point(bb.Center)
        report.append({'index':index,'name':solid_names.get(index,label),'faces':len(solid.Faces),'triangles':count,
                       'center':[round(v*scale,4) for v in p], 'top':round(199-p[1]*scale,4),
                       'colors':[colors[k][0] for k in groups]})
        total_triangles += count
    tag(tag(doc, 'scene'), 'instance_visual_scene', {'url': '#CADScene'})
    ET.ElementTree(doc).write(DEST / (output + '.dae'), encoding='utf-8', xml_declaration=True)
    manifest = {'source':filename,'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
                'freecad':'.'.join(FreeCAD.Version()[:3]), 'linearDeflectionMM':LINEAR,'angularDeflectionRadians':ANGULAR,
                'transform':'(-z, y, x)' if old else '(x, y, z)', 'uniformScale':scale,'sourceCenter':list(center),
                'sourceSizeMM':[bounds.XLength,bounds.YLength,bounds.ZLength], 'triangles':total_triangles,'solids':report}
    (DEST / (output + '.json')).write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
    print(output, 'solids',len(report),'triangles',total_triangles,'bytes',(DEST/(output+'.dae')).stat().st_size)


if __name__ == '__main__':
    DEST.mkdir(exist_ok=True, parents=True)
    build('Apple_TV_4K_Remote.step', 'SiriRemoteFirstGeneration', True)
    build('Siri Remote 2021.step', 'SiriRemoteAluminum', False)
