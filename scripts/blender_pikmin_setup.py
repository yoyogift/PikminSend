r"""
PikminSend - 雙模式 Blender 自動化算圖腳本
- MODE = "idle"  : 三隻皮克敏正面站立看你（呼吸＋搖葉子）＋ 空野餐籃
- MODE = "carry" : 環狀合力搬運野餐籃 ＋ 3D 白色文件在籃裡像《曠野之息》煮飯一樣跳動

使用方式（Windows PowerShell）：
  $env:PIKMIN_ASSET_DIR = "C:\Users\lenovo\Downloads\Pikmin"
  $env:PIKMIN_OUT_DIR = "C:\Users\lenovo\Downloads\pikmin_render_out"

  # 1. 先算待機（先設 RENDER_ANIMATION = False 看預覽，滿意改 True 算 60 幀）
  $env:PIKMIN_MODE = "idle"
  & "F:\blender\blender.exe" -b -P "C:\Users\lenovo\Downloads\blender_pikmin_setup.py"

  # 2. 再算搬運
  $env:PIKMIN_MODE = "carry"
  & "F:\blender\blender.exe" -b -P "C:\Users\lenovo\Downloads\blender_pikmin_setup.py"
"""

import math
import os
import bpy
from mathutils import Euler, Matrix, Quaternion, Vector

# ==========================================
# 1. 路徑與模式設定
# ==========================================
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ASSET_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "for blender"))
ASSET_DIR = os.environ.get("PIKMIN_ASSET_DIR", DEFAULT_ASSET_DIR)
BASE_OUT_DIR = os.environ.get("PIKMIN_OUT_DIR", os.path.join(SCRIPT_DIR, "..", "render_out"))

MODE = os.environ.get("PIKMIN_MODE", "idle").strip().lower()  # "idle" 或 "carry"
OUTPUT_DIR = os.path.join(BASE_OUT_DIR, MODE)

# 先設 False 算第 1 幀預覽圖確認，滿意後改成 True 一次算完 60 幀
RENDER_ANIMATION = False
TOTAL_FRAMES = 60
FPS = 30
RES_X = 720
RES_Y = 720

BASE_PIKMIN_HEIGHT = 0.85
OUTWARD_LEAN_DEG = 38.0


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def setup_render_and_world():
    scene = bpy.context.scene
    available_engines = {item.identifier for item in scene.render.bl_rna.properties["engine"].enum_items}
    scene.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in available_engines else "BLENDER_EEVEE"

    scene.render.film_transparent = True
    scene.render.resolution_x = RES_X
    scene.render.resolution_y = RES_Y
    scene.render.resolution_percentage = 100
    scene.render.fps = FPS
    scene.frame_start = 1
    scene.frame_end = TOTAL_FRAMES

    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    # 適中曝光，避免把黃色皮克敏洗白
    scene.view_settings.exposure = 0.25

    world = bpy.data.worlds.new("PikminSunnyWorld")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs["Color"].default_value = (0.98, 0.99, 1.0, 1.0)
        bg.inputs["Strength"].default_value = 1.65

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    scene.render.filepath = os.path.join(OUTPUT_DIR, "frame_")


def apply_texture(mesh_objects, texture_path, boost_yellow=False):
    if not os.path.exists(texture_path):
        print(f"[警告] 找不到貼圖：{texture_path}")
        return

    img = bpy.data.images.load(texture_path, check_existing=True)
    for obj in mesh_objects:
        if obj.type != "MESH":
            continue
        for mat in obj.data.materials:
            if not mat:
                continue
            mat.use_nodes = True
            nodes = mat.node_tree.nodes
            links = mat.node_tree.links
            bsdf = next((n for n in nodes if n.type == "BSDF_PRINCIPLED"), None)
            if not bsdf:
                continue

            tex_node = next((n for n in nodes if n.type == "TEX_IMAGE"), None)
            if not tex_node:
                tex_node = nodes.new("ShaderNodeTexImage")
                tex_node.location = (-500, 300)
            tex_node.image = img
            tex_node.extension = "MIRROR"

            if boost_yellow:
                hsv = nodes.new("ShaderNodeHueSaturation")
                hsv.location = (-320, 300)
                hsv.inputs["Saturation"].default_value = 2.0
                hsv.inputs["Value"].default_value = 0.95

                gamma = nodes.new("ShaderNodeGamma")
                gamma.location = (-140, 300)
                gamma.inputs["Gamma"].default_value = 1.45

                links.new(tex_node.outputs["Color"], hsv.inputs["Color"])
                links.new(hsv.outputs["Color"], gamma.inputs["Color"])
                links.new(gamma.outputs["Color"], bsdf.inputs["Base Color"])
            else:
                links.new(tex_node.outputs["Color"], bsdf.inputs["Base Color"])


def import_fbx(filepath):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=filepath, automatic_bone_orientation=True)
    after = set(bpy.data.objects)
    return list(after - before)


def measure_world_bounds(mesh_objects):
    bpy.context.view_layer.update()
    min_pt = Vector((float("inf"), float("inf"), float("inf")))
    max_pt = Vector((float("-inf"), float("-inf"), float("-inf")))
    for obj in mesh_objects:
        if obj.type != "MESH":
            continue
        for corner in obj.bound_box:
            world_pt = obj.matrix_world @ Vector(corner)
            min_pt.x = min(min_pt.x, world_pt.x)
            min_pt.y = min(min_pt.y, world_pt.y)
            min_pt.z = min(min_pt.z, world_pt.z)
            max_pt.x = max(max_pt.x, world_pt.x)
            max_pt.y = max(max_pt.y, world_pt.y)
            max_pt.z = max(max_pt.z, world_pt.z)
    if min_pt.x == float("inf"):
        return Vector((0, 0, 0)), Vector((1, 1, 1))
    return min_pt, max_pt


def align_upright_and_face_dir(armature, target_forward_xy):
    bpy.context.view_layer.update()
    pose = armature.pose.bones
    armature.rotation_mode = "QUATERNION"

    if "headjnt" in pose and "legcentre" in pose:
        foot_pos = armature.matrix_world @ pose["legcentre"].head
        head_pos = armature.matrix_world @ pose["headjnt"].head
        spine_dir = head_pos - foot_pos
        if spine_dir.length > 1e-5:
            spine_dir.normalize()
            upright_quat = spine_dir.rotation_difference(Vector((0.0, 0.0, 1.0)))
            armature.rotation_quaternion = upright_quat @ armature.rotation_quaternion
            bpy.context.view_layer.update()

    if "lhandjnt" in pose and "rhandjnt" in pose:
        l_pos = armature.matrix_world @ pose["lhandjnt"].head
        r_pos = armature.matrix_world @ pose["rhandjnt"].head
        lr_dir = Vector((l_pos.x - r_pos.x, l_pos.y - r_pos.y, 0.0))
        if lr_dir.length > 1e-5:
            lr_dir.normalize()
            desired_left = Vector((-target_forward_xy.y, target_forward_xy.x, 0.0)).normalized()
            yaw_quat = lr_dir.rotation_difference(desired_left)
            armature.rotation_quaternion = yaw_quat @ armature.rotation_quaternion
            bpy.context.view_layer.update()


def point_bone_toward_world_dir(armature, bone_name, target_world_dir):
    pose = armature.pose.bones
    if bone_name not in pose:
        return
    pbone = pose[bone_name]
    bpy.context.view_layer.update()

    current_dir_arm = pbone.tail - pbone.head
    if current_dir_arm.length < 1e-6:
        return
    current_dir_arm.normalize()

    target_dir_arm = (armature.matrix_world.inverted().to_3x3() @ target_world_dir).normalized()
    delta_arm = current_dir_arm.rotation_difference(target_dir_arm)

    local_mat = pbone.bone.matrix_local.to_3x3()
    local_quat = local_mat.to_quaternion()
    pbone.rotation_mode = "QUATERNION"
    pbone.rotation_quaternion = local_quat.inverted() @ delta_arm @ local_quat


def attach_top_sprout(armature, sprout_type):
    sprout_map = {
        "leaf": ("leaf.FBX", "piki_leaf_tex.png", 0.25),
        "bud": ("bud.FBX", "piki_bud_tex.png", 0.22),
        "flower": ("flower.FBX", "piki_flower_tex.png", 0.26),
    }
    fbx_name, tex_name, target_size = sprout_map.get(sprout_type, sprout_map["leaf"])
    fbx_path = os.path.join(ASSET_DIR, fbx_name)
    if not os.path.exists(fbx_path):
        return

    objs = import_fbx(fbx_path)
    meshes = [o for o in objs if o.type == "MESH"]
    apply_texture(meshes, os.path.join(ASSET_DIR, "Textures", tex_name))

    bpy.ops.object.empty_add(type="PLAIN_AXES", location=(0.0, 0.0, 0.0))
    root = bpy.context.active_object
    root.name = f"Sprout_{sprout_type}_{armature.name}"

    for o in objs:
        if o.parent is None:
            o.parent = root

    min_pt, max_pt = measure_world_bounds(meshes)
    span = max((max_pt - min_pt).length, 0.01)
    arm_scale = max(armature.scale.x, 0.01)
    s = (target_size / span) / arm_scale
    root.scale = (s, s, s)
    root.rotation_mode = "XYZ"
    root.rotation_euler = Euler((math.radians(-50), 0.0, 0.0), "XYZ")
    bpy.context.view_layer.update()

    target_bone = "happajnt3" if "happajnt3" in armature.pose.bones else "headjnt"
    bone_len = armature.pose.bones[target_bone].length
    root.parent = armature
    root.parent_type = "BONE"
    root.parent_bone = target_bone
    root.matrix_parent_inverse = Matrix.Identity(4)
    root.location = (0.0, -bone_len * 0.85, 0.0)


def setup_basket(location_xy=(0.0, 0.0), base_height_z=0.17, animate_carry=True):
    basket_path = None
    for name in ("basket.glb", "basket.gltf", "basket.fbx", "basket.obj"):
        candidate = os.path.join(ASSET_DIR, name)
        if os.path.exists(candidate):
            basket_path = candidate
            break

    bpy.ops.object.empty_add(type="PLAIN_AXES", location=(0.0, 0.0, 0.0))
    root = bpy.context.active_object
    root.name = "PikminBasketRoot"

    half_x, half_y, top_z = 0.6, 0.45, 0.65
    if basket_path:
        before = set(bpy.data.objects)
        ext = os.path.splitext(basket_path)[1].lower()
        if ext in (".glb", ".gltf"):
            bpy.ops.import_scene.gltf(filepath=basket_path)
        elif ext == ".fbx":
            bpy.ops.import_scene.fbx(filepath=basket_path)
        elif ext == ".obj":
            bpy.ops.wm.obj_import(filepath=basket_path)
        imported = list(set(bpy.data.objects) - before)
        meshes = [o for o in imported if o.type == "MESH"]
        for obj in imported:
            if obj.parent is None:
                obj.parent = root

        min_pt, max_pt = measure_world_bounds(meshes)
        size_x = max(max_pt.x - min_pt.x, 0.01)
        scale_factor = 1.25 / size_x
        root.scale = (scale_factor, scale_factor, scale_factor)
        bpy.context.view_layer.update()

        min_s, max_s = measure_world_bounds(meshes)
        cx = (min_s.x + max_s.x) * 0.5
        cy = (min_s.y + max_s.y) * 0.5
        root.location = (location_xy[0] - cx, location_xy[1] - cy, base_height_z - min_s.z)
        bpy.context.view_layer.update()

        min_final, max_final = measure_world_bounds(meshes)
        half_x = (max_final.x - min_final.x) * 0.5
        half_y = (max_final.y - min_final.y) * 0.5
        top_z = max_final.z

    if animate_carry:
        base_z = root.location.z
        root.rotation_mode = "XYZ"
        for frame in range(1, TOTAL_FRAMES + 1):
            t = (frame - 1) / TOTAL_FRAMES * 2.0 * math.pi
            root.location.z = base_z + abs(math.sin(t * 4.0)) * 0.02
            root.rotation_euler = (math.cos(t * 2.0) * 0.035, math.sin(t * 2.0) * 0.05, 0.0)
            root.keyframe_insert(data_path="location", frame=frame, index=2)
            root.keyframe_insert(data_path="rotation_euler", frame=frame)

    return root, half_x, half_y, top_z


def create_bouncing_3d_document(basket_top_z):
    """建立 3D 白色摺頁文件，在籃子上方做出《曠野之息》煮飯鍋食物彈跳搖晃效果"""
    bpy.ops.object.empty_add(type="PLAIN_AXES", location=(0.0, -0.05, basket_top_z - 0.14))
    doc_root = bpy.context.active_object
    doc_root.name = "BotWBouncingDocument"

    # 白色紙張主體
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0.0, 0.0, 0.0))
    paper = bpy.context.active_object
    paper.scale = (0.36, 0.035, 0.44)
    paper.parent = doc_root

    white_mat = bpy.data.materials.new("DocPaperMat")
    white_mat.use_nodes = True
    bsdf = white_mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (1.0, 1.0, 1.0, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.4
        if "Emission Color" in bsdf.inputs:
            bsdf.inputs["Emission Color"].default_value = (1.0, 1.0, 1.0, 1.0)
            bsdf.inputs["Emission Strength"].default_value = 0.25
    paper.data.materials.append(white_mat)

    # 正面加上三條橘藍色文件文字線條，遠看超清楚是文件
    line_mat = bpy.data.materials.new("DocLineMat")
    line_mat.use_nodes = True
    lbsdf = line_mat.node_tree.nodes.get("Principled BSDF")
    if lbsdf:
        lbsdf.inputs["Base Color"].default_value = (0.92, 0.48, 0.18, 1.0)

    for idx, z_off in enumerate((0.10, 0.0, -0.10)):
        bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0.0, -0.022, z_off))
        bar = bpy.context.active_object
        bar.scale = (0.24 if idx < 2 else 0.16, 0.01, 0.038)
        bar.parent = doc_root
        bar.data.materials.append(line_mat)

    base_z = doc_root.location.z
    doc_root.rotation_mode = "XYZ"
    for frame in range(1, TOTAL_FRAMES + 1):
        t = (frame - 1) / TOTAL_FRAMES * 2.0 * math.pi
        hop = abs(math.sin(t * 3.0))
        doc_root.location.z = base_z + hop * 0.18
        doc_root.rotation_euler = (
            math.cos(t * 3.0) * math.radians(10),
            math.sin(t * 2.0) * math.radians(18),
            math.sin(t * 1.5) * math.radians(8),
        )
        doc_root.scale = (1.0 - hop * 0.07, 1.0, 1.0 + hop * 0.10)
        doc_root.keyframe_insert(data_path="location", frame=frame, index=2)
        doc_root.keyframe_insert(data_path="rotation_euler", frame=frame)
        doc_root.keyframe_insert(data_path="scale", frame=frame)


# ==========================================
# 模式 A：IDLE（三隻正面看你＋空野餐籃）
# ==========================================
def build_idle_scene():
    # 空野餐籃放在後方正中央地上
    setup_basket(location_xy=(0.0, 0.28), base_height_z=0.0, animate_carry=False)

    squad = [
        ("red", "piki_red_all.png", "leaf", -0.58, -0.22, 12.0, 0.0),
        ("yellow", "piki_yellow_all.png", "bud", 0.0, -0.32, 0.0, 1.4),
        ("blue", "piki_blue_all.png", "flower", 0.58, -0.22, -12.0, 2.8),
    ]

    for color, tex, sprout, px, py, yaw_deg, phase in squad:
        fbx_path = os.path.join(ASSET_DIR, f"piki_p3_{color}.FBX")
        if not os.path.exists(fbx_path):
            continue
        imported = import_fbx(fbx_path)
        armature = next((o for o in imported if o.type == "ARMATURE"), None)
        meshes = [o for o in imported if o.type == "MESH"]
        apply_texture(meshes, os.path.join(ASSET_DIR, "Textures", tex), boost_yellow=(color == "yellow"))
        if not armature:
            continue

        armature.name = f"Armature_{color}"
        # 面向鏡頭 (-Y) 帶一點朝向中央的可愛角度
        yaw_rad = math.radians(yaw_deg)
        forward_dir = Vector((math.sin(yaw_rad), -math.cos(yaw_rad), 0.0)).normalized()
        align_upright_and_face_dir(armature, forward_dir)

        min_pt, max_pt = measure_world_bounds(meshes)
        raw_h = max(max_pt.z - min_pt.z, 0.01)
        s = BASE_PIKMIN_HEIGHT / raw_h
        armature.scale = (armature.scale.x * s, armature.scale.y * s, armature.scale.z * s)
        bpy.context.view_layer.update()

        min_s, _ = measure_world_bounds(meshes)
        armature.location = (px, py, -min_s.z)
        bpy.context.view_layer.update()

        attach_top_sprout(armature, sprout)

        # 待機姿勢：雙手自然垂放兩側，身體輕微呼吸＋葉子輕晃
        bpy.context.view_layer.objects.active = armature
        bpy.ops.object.mode_set(mode="POSE")
        point_bone_toward_world_dir(armature, "lhandjnt", Vector((0.35, -0.05, -0.85)).normalized())
        point_bone_toward_world_dir(armature, "rhandjnt", Vector((-0.35, -0.05, -0.85)).normalized())

        pose = armature.pose.bones
        for frame in range(1, TOTAL_FRAMES + 1):
            t = (frame - 1) / TOTAL_FRAMES * 2.0 * math.pi + phase
            if "kosinull" in pose:
                pose["kosinull"].location = (0.0, 0.0, math.sin(t) * 0.02)
                pose["kosinull"].keyframe_insert(data_path="location", frame=frame)
            if "happajnt1" in pose:
                pose["happajnt1"].rotation_mode = "XYZ"
                pose["happajnt1"].rotation_euler = Euler((math.sin(t) * 0.12, math.cos(t) * 0.10, 0.0), "XYZ")
                pose["happajnt1"].keyframe_insert(data_path="rotation_euler", frame=frame)
        bpy.ops.object.mode_set(mode="OBJECT")

    setup_camera_and_lights(cam_loc=(0.0, -3.15, 0.85), target_z=0.38)


# ==========================================
# 模式 B：CARRY（環狀合力搬運＋籃裡跳動 3D 文件）
# ==========================================
def build_carry_scene():
    _, half_x, half_y, top_z = setup_basket(location_xy=(0.0, 0.0), base_height_z=0.17, animate_carry=True)
    create_bouncing_3d_document(top_z)

    rx = max(half_x - 0.03, 0.35)
    ry = max(half_y - 0.03, 0.35)

    squad = [
        ("red", "piki_red_all.png", "leaf", -142.0, 0.0),
        ("yellow", "piki_yellow_all.png", "bud", -90.0, 1.2),
        ("blue", "piki_blue_all.png", "flower", -38.0, 2.4),
    ]

    for color, tex, sprout, angle_deg, phase in squad:
        fbx_path = os.path.join(ASSET_DIR, f"piki_p3_{color}.FBX")
        if not os.path.exists(fbx_path):
            continue
        imported = import_fbx(fbx_path)
        armature = next((o for o in imported if o.type == "ARMATURE"), None)
        meshes = [o for o in imported if o.type == "MESH"]
        apply_texture(meshes, os.path.join(ASSET_DIR, "Textures", tex), boost_yellow=(color == "yellow"))
        if not armature:
            continue

        armature.name = f"Armature_{color}"
        theta = math.radians(angle_deg)
        pos_x = math.cos(theta) * rx
        pos_y = math.sin(theta) * ry

        inward_dir = Vector((-pos_x, -pos_y, 0.0)).normalized()
        align_upright_and_face_dir(armature, inward_dir)

        min_pt, max_pt = measure_world_bounds(meshes)
        raw_h = max(max_pt.z - min_pt.z, 0.01)
        s = BASE_PIKMIN_HEIGHT / raw_h
        armature.scale = (armature.scale.x * s, armature.scale.y * s, armature.scale.z * s)
        bpy.context.view_layer.update()

        tangent_axis = Vector((0.0, 0.0, 1.0)).cross(inward_dir).normalized()
        lean_quat = Quaternion(tangent_axis, math.radians(-OUTWARD_LEAN_DEG))
        armature.rotation_quaternion = lean_quat @ armature.rotation_quaternion
        bpy.context.view_layer.update()

        min_s, _ = measure_world_bounds(meshes)
        armature.location = (pos_x, pos_y, -min_s.z)
        bpy.context.view_layer.update()

        attach_top_sprout(armature, sprout)

        bpy.context.view_layer.objects.active = armature
        bpy.ops.object.mode_set(mode="POSE")
        grip_dir = (inward_dir * 0.9 + Vector((0.0, 0.0, 0.35))).normalized()
        point_bone_toward_world_dir(armature, "lhandjnt", grip_dir)
        point_bone_toward_world_dir(armature, "rhandjnt", grip_dir)

        pose = armature.pose.bones
        for frame in range(1, TOTAL_FRAMES + 1):
            t = (frame - 1) / TOTAL_FRAMES * 2.0 * math.pi * 4.0 + phase
            if "llegjnt" in pose:
                pose["llegjnt"].rotation_mode = "XYZ"
                pose["llegjnt"].rotation_euler = Euler((math.sin(t) * 0.65, 0.0, 0.0), "XYZ")
                pose["llegjnt"].keyframe_insert(data_path="rotation_euler", frame=frame)
            if "rlegjnt" in pose:
                pose["rlegjnt"].rotation_mode = "XYZ"
                pose["rlegjnt"].rotation_euler = Euler((-math.sin(t) * 0.65, 0.0, 0.0), "XYZ")
                pose["rlegjnt"].keyframe_insert(data_path="rotation_euler", frame=frame)
            if "kosinull" in pose:
                pose["kosinull"].location = (0.0, 0.0, abs(math.sin(t)) * 0.04)
                pose["kosinull"].keyframe_insert(data_path="location", frame=frame)
            if "happajnt1" in pose:
                pose["happajnt1"].rotation_mode = "XYZ"
                pose["happajnt1"].rotation_euler = Euler((math.sin(t) * 0.14, math.cos(t) * 0.10, 0.0), "XYZ")
                pose["happajnt1"].keyframe_insert(data_path="rotation_euler", frame=frame)
        bpy.ops.object.mode_set(mode="OBJECT")

    setup_camera_and_lights(cam_loc=(0.0, -3.35, 1.35), target_z=0.38)


# ==========================================
# 模式 C：PEEK_IDLE（紅色長花皮克敏扶左邊牆壁探頭東張西望）
# ==========================================
def build_peek_idle_scene():
    fbx_path = os.path.join(ASSET_DIR, "piki_p3_red.FBX")
    if not os.path.exists(fbx_path):
        return
    imported = import_fbx(fbx_path)
    armature = next((o for o in imported if o.type == "ARMATURE"), None)
    meshes = [o for o in imported if o.type == "MESH"]
    apply_texture(meshes, os.path.join(ASSET_DIR, "Textures", "piki_red_all.png"))
    if not armature:
        return

    armature.name = "Armature_red_peek"
    align_upright_and_face_dir(armature, Vector((0.35, -0.94, 0.0)).normalized())

    min_pt, max_pt = measure_world_bounds(meshes)
    raw_h = max(max_pt.z - min_pt.z, 0.01)
    s = BASE_PIKMIN_HEIGHT / raw_h
    armature.scale = (armature.scale.x * s, armature.scale.y * s, armature.scale.z * s)
    bpy.context.view_layer.update()

    # 身體往右傾 22° 像扶著左邊螢幕邊緣探出頭
    armature.rotation_quaternion = Quaternion(Vector((0.0, 1.0, 0.0)), math.radians(22.0)) @ armature.rotation_quaternion
    bpy.context.view_layer.update()

    min_s, _ = measure_world_bounds(meshes)
    armature.location = (-0.42, 0.0, -min_s.z)
    bpy.context.view_layer.update()

    attach_top_sprout(armature, "flower")

    bpy.context.view_layer.objects.active = armature
    bpy.ops.object.mode_set(mode="POSE")
    # 右手往左邊伸出去「扶著牆」，左手垂在身側
    point_bone_toward_world_dir(armature, "rhandjnt", Vector((-1.0, -0.1, 0.15)).normalized())
    point_bone_toward_world_dir(armature, "lhandjnt", Vector((0.35, -0.1, -0.85)).normalized())

    pose = armature.pose.bones
    for frame in range(1, TOTAL_FRAMES + 1):
        t = (frame - 1) / TOTAL_FRAMES * 2.0 * math.pi
        if "headjnt" in pose:
            pose["headjnt"].rotation_mode = "XYZ"
            pose["headjnt"].rotation_euler = Euler((math.sin(t * 2.0) * 0.14, 0.0, math.sin(t) * 0.45), "XYZ")
            pose["headjnt"].keyframe_insert(data_path="rotation_euler", frame=frame)
        if "kosinull" in pose:
            pose["kosinull"].location = (math.sin(t) * 0.03, 0.0, abs(math.sin(t * 2.0)) * 0.015)
            pose["kosinull"].keyframe_insert(data_path="location", frame=frame)
        if "happajnt1" in pose:
            pose["happajnt1"].rotation_mode = "XYZ"
            pose["happajnt1"].rotation_euler = Euler((math.sin(t) * 0.12, math.cos(t) * 0.10, 0.0), "XYZ")
            pose["happajnt1"].keyframe_insert(data_path="rotation_euler", frame=frame)
    bpy.ops.object.mode_set(mode="OBJECT")

    setup_camera_and_lights(cam_loc=(0.0, -2.55, 0.72), target_z=0.45)


# ==========================================
# 模式 D：PEEK_WAVE（走出來一步 → 站著揮手 → 轉身走回左邊螢幕外）
# ==========================================
def build_peek_wave_scene():
    fbx_path = os.path.join(ASSET_DIR, "piki_p3_red.FBX")
    if not os.path.exists(fbx_path):
        return
    imported = import_fbx(fbx_path)
    armature = next((o for o in imported if o.type == "ARMATURE"), None)
    meshes = [o for o in imported if o.type == "MESH"]
    apply_texture(meshes, os.path.join(ASSET_DIR, "Textures", "piki_red_all.png"))
    if not armature:
        return

    armature.name = "Armature_red_wave"
    align_upright_and_face_dir(armature, Vector((0.0, -1.0, 0.0)))

    min_pt, max_pt = measure_world_bounds(meshes)
    raw_h = max(max_pt.z - min_pt.z, 0.01)
    s = BASE_PIKMIN_HEIGHT / raw_h
    armature.scale = (armature.scale.x * s, armature.scale.y * s, armature.scale.z * s)
    bpy.context.view_layer.update()

    min_s, _ = measure_world_bounds(meshes)
    base_z = -min_s.z
    armature.location = (-0.42, 0.0, base_z)
    bpy.context.view_layer.update()

    attach_top_sprout(armature, "flower")

    base_quat = armature.rotation_quaternion.copy()
    bpy.context.view_layer.objects.active = armature
    bpy.ops.object.mode_set(mode="POSE")

    point_bone_toward_world_dir(armature, "lhandjnt", Vector((0.35, -0.05, -0.85)).normalized())
    pose = armature.pose.bones

    total = 75
    bpy.context.scene.frame_end = total

    for frame in range(1, total + 1):
        if frame <= 20:
            p = (frame - 1) / 19.0
            x = -0.42 + p * 0.48
            yaw = math.radians(25.0 * (1.0 - p))
            walk_t = p * math.pi * 2.0
            wave_val = 0.0
            arm_up = False
        elif frame <= 50:
            x = 0.06
            yaw = 0.0
            walk_t = 0.0
            wave_p = (frame - 20) / 30.0
            wave_val = math.sin(wave_p * math.pi * 6.0)
            arm_up = True
        else:
            p = (frame - 50) / 25.0
            x = 0.06 - p * 1.40
            yaw = math.radians(-85.0 * min(p * 3.0, 1.0))
            walk_t = p * math.pi * 3.0
            wave_val = 0.0
            arm_up = False

        bpy.ops.object.mode_set(mode="OBJECT")
        armature.location = (x, 0.0, base_z)
        armature.rotation_quaternion = Quaternion(Vector((0.0, 0.0, 1.0)), yaw) @ base_quat
        armature.keyframe_insert(data_path="location", frame=frame, index=0)
        armature.keyframe_insert(data_path="rotation_quaternion", frame=frame)

        bpy.ops.object.mode_set(mode="POSE")
        if arm_up:
            point_bone_toward_world_dir(armature, "rhandjnt", Vector((-0.45 + wave_val * 0.25, -0.2, 0.95)).normalized())
        else:
            point_bone_toward_world_dir(armature, "rhandjnt", Vector((-0.35, -0.05, -0.85)).normalized())
        if "rhandjnt" in pose:
            pose["rhandjnt"].keyframe_insert(data_path="rotation_quaternion", frame=frame)

        if "llegjnt" in pose:
            pose["llegjnt"].rotation_mode = "XYZ"
            pose["llegjnt"].rotation_euler = Euler((math.sin(walk_t) * 0.55, 0.0, 0.0), "XYZ")
            pose["llegjnt"].keyframe_insert(data_path="rotation_euler", frame=frame)
        if "rlegjnt" in pose:
            pose["rlegjnt"].rotation_mode = "XYZ"
            pose["rlegjnt"].rotation_euler = Euler((-math.sin(walk_t) * 0.55, 0.0, 0.0), "XYZ")
            pose["rlegjnt"].keyframe_insert(data_path="rotation_euler", frame=frame)
        if "kosinull" in pose:
            pose["kosinull"].location = (0.0, 0.0, abs(math.sin(walk_t)) * 0.03)
            pose["kosinull"].keyframe_insert(data_path="location", frame=frame)

    bpy.ops.object.mode_set(mode="OBJECT")
    setup_camera_and_lights(cam_loc=(0.0, -2.55, 0.72), target_z=0.45)


def setup_camera_and_lights(cam_loc, target_z):
    bpy.ops.object.empty_add(type="PLAIN_AXES", location=(0.0, 0.0, target_z))
    target = bpy.context.active_object
    target.name = "CameraTarget"

    bpy.ops.object.camera_add(location=cam_loc)
    cam = bpy.context.active_object
    cam.data.lens = 42
    track = cam.constraints.new(type="TRACK_TO")
    track.target = target
    track.track_axis = "TRACK_NEGATIVE_Z"
    track.up_axis = "UP_Y"
    bpy.context.scene.camera = cam

    bpy.ops.object.light_add(type="SUN", location=(1.5, -3.5, 5.0))
    sun = bpy.context.active_object
    sun.data.energy = 5.2
    sun.data.color = (1.0, 0.98, 0.92)
    sun.data.angle = math.radians(20)
    sun.rotation_euler = Euler((math.radians(52), math.radians(-12), math.radians(15)), "XYZ")

    bpy.ops.object.light_add(type="AREA", location=(0.0, -3.5, 1.2))
    fill = bpy.context.active_object
    fill.data.energy = 210
    fill.data.color = (1.0, 0.99, 0.98)
    fill.data.size = 4.0


def main():
    print(f"使用素材資料夾：{ASSET_DIR} | 模式：{MODE}")
    clear_scene()
    setup_render_and_world()

    if MODE == "carry":
        build_carry_scene()
    elif MODE == "peek_idle":
        build_peek_idle_scene()
    elif MODE == "peek_wave":
        build_peek_wave_scene()
    else:
        build_idle_scene()

    blend_path = os.path.join(OUTPUT_DIR, f"pikmin_{MODE}.blend")
    bpy.ops.wm.save_as_mainfile(filepath=blend_path)
    print(f"已儲存 Blender 場景：{blend_path}")

    if RENDER_ANIMATION:
        bpy.ops.render.render(animation=True)
    else:
        bpy.context.scene.frame_set(1)
        bpy.context.scene.render.filepath = os.path.join(OUTPUT_DIR, f"preview_{MODE}.png")
        bpy.ops.render.render(write_still=True)
        print(f"已輸出第 1 幀預覽圖：{bpy.context.scene.render.filepath}")


if __name__ == "__main__":
    main()
