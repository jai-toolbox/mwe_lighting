#import "tbx/model_loading";
#import "tbx/geometry";
#import "tbx/opengl";
#import "tbx/camera";
#import "tbx/movement";
#import "tbx/collision";
#import "tbx/math";
#import "tbx/engine";
#import "tbx/physics";

#import "Basic";
#import "GL";
#import "File";
#import "Random";
#import "Math";
#import "Window_Creation";
#import "GetRect";

Simp :: #import "Simp";
using,except(Shader) Simp;

Input :: #import "Input";

convert_obj_to_indexed_meshes :: (obj_data: *Obj_Data) -> [..] Indexed_Mesh {
    meshes: [..] Indexed_Mesh;
    
    for *obj_object : obj_data.all_objects {
        mesh: Indexed_Mesh;
        current_index: u32 = 0;
        
        for *face : obj_object.faces {
            if face.face_vertices.count < 3 continue;
            
            first_index := current_index;
            
            for *fv : face.face_vertices {
                array_add(*mesh.positions, obj_data.all_positions[fv.position_index]);
                
                if fv.texture_coordinate_index >= 0 {
                    array_add(*mesh.texture_coordinates, obj_data.all_texture_coordinates[fv.texture_coordinate_index]);
                } else {
                    array_add(*mesh.texture_coordinates, .{0, 0});
                }
                
                if fv.normal_index >= 0 {
                    array_add(*mesh.normals, obj_data.all_normals[fv.normal_index]);
                } else {
                    array_add(*mesh.normals, .{0, 1, 0});
                }

                current_index += 1;
            }
            
            for i : 1..face.face_vertices.count-2 {
                array_add(*mesh.indices, first_index);
                array_add(*mesh.indices, first_index + cast(u32) i);
                array_add(*mesh.indices, first_index + cast(u32) i + 1);
            }
        }

        if mesh.positions.count > 0 {
            min_pos := mesh.positions[0];
            max_pos := mesh.positions[0];

            for mesh.positions {
                min_pos.x = min(min_pos.x, it.x);
                min_pos.y = min(min_pos.y, it.y);
                min_pos.z = min(min_pos.z, it.z);
                max_pos.x = max(max_pos.x, it.x);
                max_pos.y = max(max_pos.y, it.y);
                max_pos.z = max(max_pos.z, it.z);
            }

            range := max_pos - min_pos;

            if range.x < 0.0001 range.x = 1.0;
            if range.y < 0.0001 range.y = 1.0;
            if range.z < 0.0001 range.z = 1.0;

            for mesh.positions {
                t := (it - min_pos);
                color := Vector3.{
                    t.x / range.x,
                    t.y / range.y,
                    t.z / range.z,
                };

                color = .{0.5, 0.5, 0.5};
                array_add(*mesh.rgb_colors, color);
            }
        }
        
        array_add(*meshes, mesh);
    }
    
    return meshes;
}

Character :: struct {
    using #as cg : Collision_Geometry;
    renderable : Camera_Per_Object_Transform_Color_Renderable;
}

main :: () {
    windowed_program_3d : Windowed_Program_3D;
    windowed_program_3d.movement_mode = .MANUAL;
    windowed_program_3d.camera_mode = .FIRST_PERSON;
    windowed_program_3d.window_width = 1000;
    windowed_program_3d.window_height = 1000;
    windowed_program_3d.window_name = "mwe_collision";

    windowed_program_3d.camera.offset = Y3 * 1.75 * 0.25;

    init(*windowed_program_3d); // opengl initialized after this point

    deferred_lighting : Deferred_Lighting;
    init(*deferred_lighting, windowed_program_3d.window_width, windowed_program_3d.window_height);

    add_light(*deferred_lighting, .{0, 10, 0}, .{1.0, 1.0, 1.0});   // white overhead
    // add_light(*deferred_lighting, .{-3.0, 2.0, 1.0}, .{1.0, 0.2, 0.2});   // reddish
    // add_light(*deferred_lighting, .{0.0, 1.5, 3.0},  .{0.2, 0.2, 1.0});   // bluish

    obj_data := load_obj("data/lair.obj");
    meshes := convert_obj_to_indexed_meshes(*obj_data);

    map : Collision_Geometries;

    movement_mode := Movement_Mode.FPS;

    for meshes {
        cg : Collision_Geometry;
        cg.indexed_triangle_positions.indices = it.indices;
        cg.indexed_triangle_positions.positions = it.positions;
        cg.aabb = create_aabb_from_positions(cg.indexed_triangle_positions.positions);

        array_add(*map.indexed_triangle_positions, cg.indexed_triangle_positions);
        array_add(*map.aabbs, cg.aabb);
    }

    character : Character;
    character.indexed_triangle_positions = create_box(ZERO3, 0.4, 1.75, 0.4); 
    character.aabb = create_aabb_from_positions(character.indexed_triangle_positions.positions);

    windowed_program_3d.camera.position = Y3 * 2;
    velocity : Vector3;
    on_ground : bool;

    map_renderables : [..] Camera_Per_Object_Transform_Deferred_Lighting_Geometry_Pass_Renderable;
    
    for meshes {
        renderable : Camera_Per_Object_Transform_Deferred_Lighting_Geometry_Pass_Renderable;
        renderable.indices = it.indices;
        renderable.positions = it.positions;
        renderable.rgb_colors = it.rgb_colors;
        renderable.normals = it.normals;

        buffer_object(*deferred_lighting.geometry_pass_renderer, *renderable);

        array_add(*map_renderables, renderable);
    }

    while !windowed_program_3d.end_program {

        mark_frame_start(*windowed_program_3d);

        if is_key_just_pressed(xx #char "M")
            toggle_menu(*windowed_program_3d);

        per_frame_update(*windowed_program_3d);

        if (windowed_program_3d.current_menu == .NONE) {

            old_velocity := velocity;
            new_velocity : Vector3;
            if (movement_mode == .FPS) {
                fpmi := First_Person_Movement_Input.{
                    is_key_down (xx #char "W"),
                    is_key_down (xx #char "S"),
                    is_key_down (xx #char "D"),
                    is_key_down (xx #char "A"),
                    is_key_down (xx #char " "),
                }; 

                ground_state : Ground_State = ifx on_ground then .ON_GROUND else .IN_AIR;

                new_velocity = get_new_first_person_velocity(velocity, fpmi, get_forward(*windowed_program_3d.camera), windowed_program_3d.delta_time, ground_state, Movement_Params.{acceleration_mpss = 20});
            }

            ellipsoid_radius := v3(0.4, 1.75 / 2, 0.4);  
            displacement := displacement_from_kinematic_update(old_velocity, new_velocity, windowed_program_3d.delta_time);
            resolve_collisions_against_body_ellipsoid(map, ellipsoid_radius, *windowed_program_3d.camera.position, *displacement, *on_ground);

            velocity = new_velocity;

            glUseProgram(deferred_lighting.geometry_pass_renderer.shader_program_gl_handle);
            set_world_to_camera_uniform(*deferred_lighting.geometry_pass_renderer, windowed_program_3d.camera.world_to_camera);
            set_camera_to_clip_uniform(*deferred_lighting.geometry_pass_renderer, windowed_program_3d.camera.camera_to_clip);
            glUseProgram(0);

            glUseProgram(deferred_lighting.compute_light_pass_renderer.shader_program_gl_handle);
            set_aspect_ratio_uniform(*deferred_lighting.compute_light_pass_renderer, Vector2.{xx windowed_program_3d.window_width, xx windowed_program_3d.window_height});
            glUseProgram(0);

            for map_renderables queue_render(*deferred_lighting.geometry_pass_renderer, it.object_index);

            Simp.update_window(windowed_program_3d.window);

            glDepthMask(GL_TRUE);
            glEnable(GL_DEPTH_TEST);

            render(*deferred_lighting, windowed_program_3d.camera.position);

            // we render the ui on top
            context.simp.current_shader = null;
            render_tick_stats(*windowed_program_3d);
            render_camera_stats(*windowed_program_3d);

            swap_buffers(windowed_program_3d.window, false);

            context.simp.current_shader = null; 
        } else {
            context.simp.current_shader = null;
            clear_render_target(.35, .35, .35, 1);
            render_menus(*windowed_program_3d.wp);
            swap_buffers(windowed_program_3d.window, false);
        }

        sleep_to_maintain_max_fps(*windowed_program_3d);
        mark_frame_end(*windowed_program_3d);
    }

    deinit(*deferred_lighting);
}

do_collision_simulation :: (windowed_program_3d : *Windowed_Program_3D, delta_time : float, velocity : *Vector3, on_ground : *bool, character : *Character, map : Collision_Geometries, map_renderables: [] Camera_Per_Object_Transform_Color_Renderable, movement_mode: Movement_Mode) {


}
