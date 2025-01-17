#  NOTE -  This is taken from Skeleton.jl
# I just want to work on it and adopt it for my entire model and mechanism file.

# FIXME - Do I need to mention packages or something? I have to figure the dependencies out.
# These are all the packages that are used in scr/MechanismGeometries.jl

# SECTION - Transformations settings

# REVIEW: What are these for?
# Seems to be putting rotations and translations together
# What is an affine map? Is it p_new = R*p_old+T?
to_affine_map(tform::Transform3D) = AffineMap(rotation(tform), translation(tform))

rotation_from_x_axis(translation::AbstractVector{T}) where {T} = rotation_between(SVector{3, T}(1,0,0), translation)
# !SECTION - Transformations settings

# SECTION - Functions related to inertial ellipsoids

# I don't need these functions related to ellipsoids 
function inertial_ellipsoid_dimensions(mass, axis_inertias)
    # Ix = m/5 (dy^2 + dz^2)
    # Iy = m/5 (dx^2 + dz^2)
    # Iz = m/5 (dx^2 + dy^2)
    #
    # let A = [0 1 1
    #          1 0 1
    #          1 1 0]
    # b = 5 / m * [Ix; Iy; Iz]
    # Then A \ b = [dx^2; dy^2; dz^2]
    #
    # This is only valid if the axis inertias obey the triangle inequalities:
    # Ix + Iy >= Iz
    # Ix + Iz >= Iy
    # Iy + Iz >= Ix

    # Ix - Iy = m/5 (dy^2 - dx^2)
    # Ix - Iy + Iz = m/5 (2*dy^2)
    # dy^2 = 0.5 (Ix - Iy + Iz) * 5/m


    squared_lengths = 0.5 * 5.0 / mass *
        [-axis_inertias[1] + axis_inertias[2] + axis_inertias[3];
          axis_inertias[1] - axis_inertias[2] + axis_inertias[3];
          axis_inertias[1] + axis_inertias[2] - axis_inertias[3]]

    for i = 1:3
        total_inertia_of_other_axes = zero(axis_inertias[1])
        for j = 1:3
            if i == j
                continue
            end
            total_inertia_of_other_axes += axis_inertias[j]
        end
        if axis_inertias[i] > total_inertia_of_other_axes
            error("Principal inertias $(axis_inertias) do not satisfy the triangle inequalities, so the equivalent inertial ellipsoid is not well-defined.")
        end
    end

    return sqrt.(squared_lengths)
end

inertial_ellipsoid(body::RigidBody) = inertial_ellipsoid(spatial_inertia(body))

if VERSION < v"0.7.0-DEV.5211"
    const _eigen = eig
else
    const _eigen = eigen
end

function inertial_ellipsoid(inertia::SpatialInertia)
    com_frame = CartesianFrame3D("CoM")
    com_frame_to_inertia_frame = Transform3D(com_frame, inertia.frame, center_of_mass(inertia).v)
    com_inertia = transform(inertia, inv(com_frame_to_inertia_frame))
    principal_inertias, axes = _eigen(Array(com_inertia.moment)) # StaticArrays.eig checks that the matrix is Hermitian with zero tolerance...
    axes[:,3] *= sign(dot(cross(axes[:,1], axes[:,2]), axes[:,3])) # Ensure the axes form a right-handed coordinate system
    radii = inertial_ellipsoid_dimensions(com_inertia.mass, principal_inertias)
    # We create an ellipsoid by generating a sphere and then scaling it
    # along each axis
    geometry = HyperSphere(zero(Point{3, Float64}), 1.0)
    scaling = LinearMap(SDiagonal(radii[1], radii[2], radii[3]))
    tform = AffineMap(RotMatrix{3}(axes), center_of_mass(inertia).v) ∘ scaling
    return VisualElement(inertia.frame, geometry, DEFAULT_COLOR, tform)
end
# !SECTION - Functions related to inertial ellipsoids

# SECTION - Joint to joint line, useful for my cable

function create_frame_to_frame_geometry(joint_to_joint, radius)
    trans = translation(joint_to_joint)
    geom_length = norm(trans)
    radius = min(radius, geom_length)
    tform = if norm(trans) > 1e-10
        LinearMap(rotation_from_x_axis(trans))
    else
        IdentityTransformation()
    end
    geometry = Rect(Vec(0, -radius, -radius), Vec(geom_length, 2*radius, 2*radius))
    return VisualElement(joint_to_joint.to, geometry, DEFAULT_COLOR, tform)
end
# !SECTION - Joint to joint line, useful for my cable


# NOTE - Function for finding link lengths (straight lines, joint to joint)
# I can use it for my cable lengths, easily can be used for a rigid cable.
# I have to edit it a bit for a flexible cable.
# It just calculates a distance (max!)
function maximum_link_length(body_fixed_joint_frames::Dict{RigidBody{T}, Vector{CartesianFrame3D}}) where T
    result = zero(T)
    for (body, joint_frames) in body_fixed_joint_frames
        for framei in joint_frames, framej in joint_frames
            transform = fixed_transform(body, framei, framej)
            result = max(result, norm(translation(transform)))
        end
    end
    result
end

# NOTE - Skeleton struct definition as an AbstractGeometrySource
# TODO - I can add more parameters. Good for my extensions
struct mySkel <: AbstractGeometrySource
    inertias::Bool
    randomize_colors::Bool
end
# REVIEW -  What does this line do? Is it setting default values?
mySkel(; inertias=false, randomize_colors=true) = mySkel(inertias, randomize_colors)

# SECTION - Takes in Mechanism, Gives the elements.
# NOTE - Takes some deep dive and edits here to extend it for my whole mechanisms
# TODO - Function for different cables (rigid/elastic)
# TODO - Function for quadrotor Meshes/Obj
# TODO - Function for the Platform (poly will be the most general one)
# TODO - Visualizing the Anchors, COM of the masses?

function visual_elements(mechanism::Mechanism, source::mySkel)
    # REVIEW - What does this mean?!!
    # Does it take all the joints connected to a certain body?
    # It is used to find the links.
    # TODO - Test in REPEL
    body_fixed_joint_frames = Dict(body => begin
        [map(frame_before, out_joints(body, mechanism)); map(frame_after, in_joints(body, mechanism))]
    end for body in bodies(mechanism))

    box_width = 0.1 * maximum_link_length(body_fixed_joint_frames)
    #box_width = 0.5

    # NOTE - Initializing Elements Vector, Elements will be pushed to it
    elements = Vector{VisualElement}()


    # SECTION - Loops in Mechanism begins here
    # TODO - Find other functions to navigate the properties of a mechanism.
    # Start with the source of these functions.

    for body in bodies(mechanism)
        # Inertia Check and visuals
        
        if source.inertias && has_defined_inertia(body) && spatial_inertia(body).mass >= 1e-3
            push!(elements, inertial_ellipsoid(body))
        else
            for joint in out_joints(body, mechanism)
                if !iszero(box_width)
                    push!(elements, VisualElement(
                        frame_before(joint),
                        HyperSphere{3, Float64}(zero(Point{3, Float64}), box_width),
                        DEFAULT_COLOR,
                        IdentityTransformation()
                    ))
                end
            end
        end
        frames = body_fixed_joint_frames[body]
        # Connecting joints with a link
        for (i, framei) in enumerate(frames)
            for j = i + 1 : length(frames)
                framej = frames[j]
                joint_to_joint = fixed_transform(mechanism, framei, framej)
                push!(elements, create_frame_to_frame_geometry(
                    joint_to_joint,
                    box_width / 2
                ))
            end
        end
    end
    # !SECTION - Loops in Mechanism ends here

    # NOTE - Color settings
    # TODO - Different elements, different colors
    if source.randomize_colors
        for element in elements
            element.color = RGBA{Float32}(rand(), rand(), rand(), 0.5)
        end
    end
    elements
end
# !SECTION - Takes in Mechanism, Gives the elements.