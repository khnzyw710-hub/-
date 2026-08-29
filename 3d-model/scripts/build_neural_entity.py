"""
Procedurally builds "NEURAL ENTITY" — a humanoid figure whose body is a soft
holographic silhouette overlaid with a glowing constellation-style neural
network mesh (nodes + tapered connecting struts), and exports it as a
high-quality, self-contained glTF binary (.glb).

Run headless with:
    blender --background --factory-startup --python build_neural_entity.py
"""

import bpy
import bmesh
import math
import random
import sys
from mathutils import Vector, kdtree

random.seed(7)

OUT_DIR = "/home/user/-/3d-model/output"
GLB_PATH = f"{OUT_DIR}/neural_entity.glb"


# ---------------------------------------------------------------------------
# scene reset
# ---------------------------------------------------------------------------
def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for coll in list(bpy.data.collections):
        bpy.data.collections.remove(coll)
    for block_group in (bpy.data.meshes, bpy.data.metaballs, bpy.data.materials,
                        bpy.data.objects, bpy.data.images):
        for block in list(block_group):
            block_group.remove(block)


# ---------------------------------------------------------------------------
# humanoid base mesh (metaball capsule-man, converted + cleaned to a mesh)
# ---------------------------------------------------------------------------
def add_balls(mball, p0, p1, r0, r1, n=6, neg_ends=0):
    """Interpolate n metaball elements from p0 to p1 with tapering radius."""
    for i in range(n):
        t = i / (n - 1)
        co = p0.lerp(p1, t)
        r = r0 + (r1 - r0) * t
        el = mball.elements.new()
        el.co = co
        el.radius = r
        el.stiffness = 2.0


def build_humanoid_metaballs():
    mball = bpy.data.metaballs.new("NeuralEntityMBall")
    mball.resolution = 0.014
    mball.render_resolution = 0.014
    mball.threshold = 0.35
    obj = bpy.data.objects.new("Humanoid_Meta", mball)
    bpy.context.collection.objects.link(obj)

    P = lambda x, y, z: Vector((x, y, z))

    # key joints (meters, Z-up, character faces +Y)
    head_c = P(0, 0, 1.685)
    neck = P(0, 0, 1.545)
    chest = P(0, 0, 1.40)
    solar = P(0, 0, 1.27)
    waist = P(0, 0, 1.13)
    pelvis = P(0, 0, 1.00)

    sh_l, sh_r = P(-0.205, 0.01, 1.475), P(0.205, 0.01, 1.475)
    el_l, el_r = P(-0.315, 0.02, 1.195), P(0.315, 0.02, 1.195)
    wr_l, wr_r = P(-0.375, 0.03, 0.915), P(0.375, 0.03, 0.915)
    hand_l, hand_r = P(-0.40, 0.045, 0.79), P(0.40, 0.045, 0.79)

    hip_l, hip_r = P(-0.115, 0, 0.955), P(0.115, 0, 0.955)
    knee_l, knee_r = P(-0.135, 0.01, 0.535), P(0.135, 0.01, 0.535)
    ank_l, ank_r = P(-0.145, 0.0, 0.105), P(0.145, 0.0, 0.105)
    foot_l, foot_r = P(-0.145, 0.135, 0.028), P(0.145, 0.135, 0.028)

    # head + neck
    add_balls(mball, neck, head_c, 0.075, 0.075, n=3)
    el = mball.elements.new(); el.co = head_c; el.radius = 0.115; el.stiffness = 2.2
    el = mball.elements.new(); el.co = head_c + P(0, -0.015, 0.02); el.radius = 0.10; el.stiffness = 2.0

    # torso spine
    add_balls(mball, neck, chest, 0.10, 0.145, n=3)
    add_balls(mball, chest, solar, 0.145, 0.135, n=3)
    add_balls(mball, solar, waist, 0.135, 0.105, n=3)
    add_balls(mball, waist, pelvis, 0.105, 0.115, n=3)

    # shoulders / hips anchors
    for c in (sh_l, sh_r):
        el = mball.elements.new(); el.co = c; el.radius = 0.085; el.stiffness = 2.0
    for c in (hip_l, hip_r):
        el = mball.elements.new(); el.co = c; el.radius = 0.095; el.stiffness = 2.0

    # arms
    for sh, el_j, wr, hand, sign in ((sh_l, el_l, wr_l, hand_l, -1), (sh_r, el_r, wr_r, hand_r, 1)):
        add_balls(mball, sh, el_j, 0.062, 0.046, n=5)
        add_balls(mball, el_j, wr, 0.046, 0.033, n=5)
        add_balls(mball, wr, hand, 0.033, 0.026, n=3)
        e = mball.elements.new(); e.co = hand + Vector((sign * 0.01, 0.01, -0.03)); e.radius = 0.028; e.stiffness = 1.8

    # legs
    for hip, knee, ank, foot in ((hip_l, knee_l, ank_l, foot_l), (hip_r, knee_r, ank_r, foot_r)):
        add_balls(mball, hip, knee, 0.095, 0.062, n=5)
        add_balls(mball, knee, ank, 0.062, 0.044, n=5)
        e = mball.elements.new(); e.co = ank; e.radius = 0.046; e.stiffness = 2.0
        e = mball.elements.new(); e.co = foot; e.radius = 0.05; e.stiffness = 1.8
        e = mball.elements.new(); e.co = (ank + foot) / 2; e.radius = 0.045; e.stiffness = 1.8

    return obj


def metaball_to_clean_mesh(mball_obj):
    vl = bpy.context.view_layer
    bpy.ops.object.select_all(action='DESELECT')
    mball_obj.select_set(True)
    vl.objects.active = mball_obj
    bpy.ops.object.convert(target='MESH')
    mesh_obj = vl.objects.active
    mesh_obj.name = "Body_Silhouette"

    # voxel remesh -> even, closed, high-quality topology
    rm = mesh_obj.modifiers.new("Remesh", 'REMESH')
    rm.mode = 'VOXEL'
    rm.voxel_size = 0.011
    rm.adaptivity = 0.0
    bpy.ops.object.modifier_apply(modifier=rm.name)

    sm = mesh_obj.modifiers.new("Smooth", 'SMOOTH')
    sm.iterations = 6
    sm.factor = 0.5
    bpy.ops.object.modifier_apply(modifier=sm.name)

    sm2 = mesh_obj.modifiers.new("CorrectiveSmooth", 'CORRECTIVE_SMOOTH')
    sm2.iterations = 10
    sm2.factor = 0.7
    bpy.ops.object.modifier_apply(modifier=sm2.name)

    sub = mesh_obj.modifiers.new("Subsurf", 'SUBSURF')
    sub.levels = 3
    sub.render_levels = 3
    bpy.ops.object.modifier_apply(modifier=sub.name)

    bpy.ops.object.shade_smooth()
    return mesh_obj


# ---------------------------------------------------------------------------
# glowing neural network overlay (nodes + tapered struts via Skin modifier)
# ---------------------------------------------------------------------------
def sample_surface_points(mesh_obj, target_count=650):
    """Decimate a copy of the body mesh and return its vertices/normals
    *and* its own topological edges, so the network we build from them
    always runs along the surface and never cuts through the body."""
    dup = mesh_obj.copy()
    dup.data = mesh_obj.data.copy()
    bpy.context.collection.objects.link(dup)

    dec = dup.modifiers.new("Decimate", 'DECIMATE')
    verts_now = len(dup.data.vertices)
    ratio = min(1.0, target_count / max(verts_now, 1))
    dec.ratio = max(ratio, 0.01)
    bpy.ops.object.select_all(action='DESELECT')
    dup.select_set(True)
    bpy.context.view_layer.objects.active = dup
    bpy.ops.object.modifier_apply(modifier=dec.name)

    mesh = dup.data
    mesh.calc_normals_split()
    points, normals = [], []
    for v in mesh.vertices:
        points.append(dup.matrix_world @ v.co)
        normals.append((dup.matrix_world.to_3x3() @ v.normal).normalized())
    topo_edges = [tuple(e.vertices) for e in mesh.edges]

    bpy.data.objects.remove(dup, do_unlink=True)
    return points, normals, topo_edges


def build_network_edges(points, topo_edges, long_link_chance=0.012, long_radius=0.4):
    """Use the decimated mesh's own edges as the network's struts (they run
    along the surface by construction), plus a sparse sprinkle of longer
    'synapse' links between nearby-but-unconnected nodes for visual interest."""
    edges = set(tuple(sorted(e)) for e in topo_edges)

    kd = kdtree.KDTree(len(points))
    for i, p in enumerate(points):
        kd.insert(p, i)
    kd.balance()

    for i, p in enumerate(points):
        if random.random() < long_link_chance:
            candidates = kd.find_range(p, long_radius)
            far = [c for c in candidates
                   if long_radius * 0.5 < c[2] <= long_radius and c[1] != i]
            if far:
                idx = random.choice(far)[1]
                edges.add(tuple(sorted((i, idx))))

    degree = [0] * len(points)
    for a, b in edges:
        degree[a] += 1
        degree[b] += 1

    return list(edges), degree


LANDMARK_RADIUS = 0.042
HUB_RADIUS = 0.018
NODE_RADIUS = 0.006
STRUT_RADIUS = 0.0028


def build_network_mesh(points, normals, edges, degree, offset=0.012):
    mesh = bpy.data.meshes.new("NeuralNetworkMesh")
    offset_pts = [p + n * offset for p, n in zip(points, normals)]
    mesh.from_pydata(offset_pts, edges, [])
    mesh.update()

    obj = bpy.data.objects.new("Neural_Network", mesh)
    bpy.context.collection.objects.link(obj)

    skin = obj.modifiers.new("Skin", 'SKIN')
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    skin_layer = mesh.skin_vertices[0].data
    z_max = max(p.z for p in points)
    z_min = min(p.z for p in points)
    for i, sv in enumerate(skin_layer):
        d = degree[i]
        p = points[i]
        # landmark = extremity-ish node (near head top, hands, feet) gets a big glowing node
        is_landmark = (p.z > z_max - 0.05) or (p.z < z_min + 0.06)
        if is_landmark and d >= 1:
            r = LANDMARK_RADIUS
        elif d >= 5:
            r = HUB_RADIUS
        else:
            r = NODE_RADIUS
        sv.radius = (r, r)

    for e in mesh.edge_keys:
        pass  # per-edge radius not needed; skin interpolates from vertex radii

    sub = obj.modifiers.new("Subsurf", 'SUBSURF')
    sub.levels = 1
    sub.render_levels = 1

    bpy.ops.object.modifier_apply(modifier="Skin")
    bpy.ops.object.modifier_apply(modifier="Subsurf")
    bpy.ops.object.shade_smooth()
    return obj


# ---------------------------------------------------------------------------
# materials
# ---------------------------------------------------------------------------
def make_body_material():
    mat = bpy.data.materials.new("Body_Hologram")
    mat.use_nodes = True
    mat.blend_method = 'BLEND'
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Base Color"].default_value = (0.015, 0.03, 0.05, 1.0)
    bsdf.inputs["Metallic"].default_value = 0.15
    bsdf.inputs["Roughness"].default_value = 0.30
    bsdf.inputs["Emission Color"].default_value = (0.05, 0.28, 0.42, 1.0)
    bsdf.inputs["Emission Strength"].default_value = 0.9
    bsdf.inputs["Alpha"].default_value = 0.38
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    return mat


def make_network_material():
    mat = bpy.data.materials.new("Neural_Glow")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Base Color"].default_value = (0.55, 0.92, 1.0, 1.0)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 0.18
    bsdf.inputs["Emission Color"].default_value = (0.25, 0.85, 1.0, 1.0)
    bsdf.inputs["Emission Strength"].default_value = 2.2
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    return mat


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    reset_scene()

    mball_obj = build_humanoid_metaballs()
    body = metaball_to_clean_mesh(mball_obj)
    print(f"[build] body mesh verts={len(body.data.vertices)} polys={len(body.data.polygons)}")

    points, normals, topo_edges = sample_surface_points(body, target_count=650)
    print(f"[build] sampled {len(points)} network node candidates")

    edges, degree = build_network_edges(points, topo_edges, long_link_chance=0.012, long_radius=0.4)
    print(f"[build] network edges={len(edges)}")

    network = build_network_mesh(points, normals, edges, degree, offset=0.012)
    print(f"[build] network mesh verts={len(network.data.vertices)} polys={len(network.data.polygons)}")

    body_mat = make_body_material()
    net_mat = make_network_material()
    body.data.materials.append(body_mat)
    network.data.materials.append(net_mat)

    root = bpy.data.objects.new("NeuralEntity", None)
    bpy.context.collection.objects.link(root)
    body.parent = root
    network.parent = root

    import os
    os.makedirs(OUT_DIR, exist_ok=True)
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH,
        export_format='GLB',
        use_selection=False,
        export_apply=True,
        export_materials='EXPORT',
        export_yup=True,
        export_cameras=False,
        export_lights=False,
        export_animations=False,
    )
    print(f"[build] exported -> {GLB_PATH}")

    blend_path = f"{OUT_DIR}/neural_entity.blend"
    bpy.ops.wm.save_as_mainfile(filepath=blend_path)
    print(f"[build] saved -> {blend_path}")


if __name__ == "__main__":
    main()
