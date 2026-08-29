"""Render a quick preview of the exported neural entity for visual QA."""
import bpy
import math
import os

BLEND = "/home/user/-/3d-model/output/neural_entity.blend"
OUT_DIR = "/home/user/-/3d-model/output"

bpy.ops.wm.open_mainfile(filepath=BLEND)
scn = bpy.context.scene

scn.render.engine = 'CYCLES'
scn.cycles.device = 'CPU'
scn.cycles.samples = 48
scn.cycles.use_denoising = False
scn.view_layers[0].cycles.use_denoising = False
scn.render.resolution_x = 900
scn.render.resolution_y = 1200
scn.render.film_transparent = False

world = bpy.data.worlds.new("World") if not scn.world else scn.world
scn.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
bg.inputs[0].default_value = (0.005, 0.008, 0.015, 1.0)
bg.inputs[1].default_value = 1.0

scn.view_settings.view_transform = 'Standard'
scn.view_settings.look = 'None'
scn.view_settings.exposure = 0.0

# key + rim lights (kept low-energy so the dark hologram body and the
# emissive network don't clip to white)
key = bpy.data.objects.new("Key", bpy.data.lights.new("Key", 'AREA'))
key.data.energy = 35
key.data.size = 2.0
key.location = (2.0, -2.5, 2.4)
key.rotation_euler = (math.radians(60), 0, math.radians(35))
bpy.context.collection.objects.link(key)

rim = bpy.data.objects.new("Rim", bpy.data.lights.new("Rim", 'AREA'))
rim.data.energy = 20
rim.data.size = 2.0
rim.data.color = (0.4, 0.8, 1.0)
rim.location = (-2.2, 2.0, 1.6)
rim.rotation_euler = (math.radians(70), 0, math.radians(-120))
bpy.context.collection.objects.link(rim)

fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", 'AREA'))
fill.data.energy = 8
fill.data.size = 3.0
fill.data.color = (0.3, 0.5, 0.7)
fill.location = (0.0, -3.0, -0.5)
fill.rotation_euler = (math.radians(-100), 0, 0)
bpy.context.collection.objects.link(fill)

cam_data = bpy.data.cameras.new("Cam")
cam = bpy.data.objects.new("Cam", cam_data)
bpy.context.collection.objects.link(cam)
cam.location = (0, -3.4, 1.05)
cam.rotation_euler = (math.radians(90), 0, 0)
cam_data.lens = 50
scn.camera = cam

os.makedirs(OUT_DIR, exist_ok=True)
scn.render.filepath = f"{OUT_DIR}/preview_front.png"
bpy.ops.render.render(write_still=True)
print("[preview] wrote", scn.render.filepath)

# 3/4 angle
cam.location = (2.6, -2.6, 1.4)
cam.rotation_euler = (math.radians(78), 0, math.radians(45))
scn.render.filepath = f"{OUT_DIR}/preview_3q.png"
bpy.ops.render.render(write_still=True)
print("[preview] wrote", scn.render.filepath)
