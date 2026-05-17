# Waveguide ARC Connector for KLayout
#
# Workflow:
# 1. Draw the two orthogonal rectangular waveguide boxes.
# 2. Draw/select one ruler from the desired start area to the desired end area.
# 3. Select the two rectangle boxes too.
# 4. Run this script, choose the curve direction, and enter one centerline radius
#    per requested ARC PCell.
#
# The script snaps the ruler endpoints to the nearest box edge centers, infers
# waveguide width and layer from the rectangles, and creates only Basic.ARC PCell
# instances. It rejects radius sets that cannot close the connection without gaps.

include RBA

module WaveguideArcConnector

  TITLE = "Waveguide ARC Connector"
  MIN_ANGLE_RAD = 1.0e-7
  MAX_ANGLE_RAD = 1.75 * Math::PI
  DEG = 180.0 / Math::PI
  RAD = Math::PI / 180.0

  module_function

  def run
    view = current_view
    unless view
      puts "#{TITLE}: open a layout view before running this script."
      return
    end

    cv = view.active_cellview
    unless cv && cv.is_valid? && cv.layout && cv.cell
      fail_dialog("No active editable cell view was found.")
      return
    end

    ruler = selected_ruler(view)
    return unless ruler

    boxes = selected_boxes(view, cv.index)
    if boxes.size < 2
      fail_dialog("Select the two rectangular waveguide boxes, plus one ruler marking the connection direction.")
      return
    end

    connection = build_connection(boxes, ruler, cv.layout)
    return unless connection

    direction = ask_curve_direction(connection)
    return if direction.nil?

    radii_text = ask_radii(connection, direction)
    return if radii_text.nil?

    radii = parse_radii(radii_text)
    if radii.empty?
      fail_dialog("Enter at least one positive centerline radius, for example: 50,50")
      return
    end

    if radii.size > 8
      fail_dialog("This script supports up to 8 ARC PCell bends at once. Use fewer radii or split the connection.")
      return
    end

    min_radius = connection[:width] * 0.5
    too_small = radii.find { |r| r <= min_radius }
    if too_small
      fail_dialog("Radius #{fmt(too_small)} um is not larger than half the waveguide width (#{fmt(min_radius)} um).")
      return
    end

    npoints_default = default_npoints(radii, connection[:width])
    npoints = InputDialog.ask_int_ex(TITLE, "Interpolation points per full circle:", npoints_default, 8, 1024, 1)
    return if npoints.nil?

    solution = solve_connection(connection, radii, direction)
    unless solution[:ok]
      movable = movable_end_rectangle_solution(connection, radii, direction)
      unless movable && ask_move_end_rectangle(connection, solution, movable)
        fail_dialog([
          "No gap-free arc-only solution was found for those radii.",
          "Best residual: #{fmt(solution[:pos_error])} um and #{fmt(solution[:angle_error] * DEG)} deg.",
          "Try adding another radius, changing the radii, or moving the selected endpoints."
        ].join("\n"))
        return
      end

      connection = moved_finish_connection(connection, movable[:finish])
      place_arcs(view, cv, connection, radii, movable[:angles], npoints.to_i, movable)
      return
    end

    place_arcs(view, cv, connection, radii, solution[:angles], npoints.to_i)
  rescue => e
    fail_dialog("#{e.class}: #{e.message}\n\n#{e.backtrace.first}")
  end

  def current_view
    app = Application.instance
    mw = app && app.main_window
    mw && mw.current_view
  end

  def fail_dialog(text)
    if current_view
      MessageBox.warning(TITLE, text, MessageBox::Ok)
    else
      puts "#{TITLE}: #{text}"
    end
  end

  def info_dialog(text)
    if current_view
      MessageBox.info(TITLE, text, MessageBox::Ok)
    else
      puts "#{TITLE}: #{text}"
    end
  end

  def selected_ruler(view)
    rulers = []
    view.each_annotation_selected { |a| rulers << a }

    if rulers.empty?
      fail_dialog("Select exactly one ruler. Its p1 endpoint is the start side and p2 endpoint is the end side.")
      return nil
    end

    if rulers.size > 1
      fail_dialog("Select only one ruler for the start and end points.")
      return nil
    end

    rulers.first
  end

  def selected_boxes(view, cv_index)
    boxes = []

    view.each_object_selected do |s|
      next if s.is_cell_inst?
      next unless s.cv_index == cv_index
      next unless s.shape && s.shape.is_box?

      box = s.shape.dbox
      next unless box

      transformed = box.transformed(s.dtrans)
      boxes << {
        selection: s,
        box: transformed,
        layer: s.layer,
        direct: s.dtrans.is_unity?
      }
    end

    boxes
  end

  def build_connection(boxes, ruler, layout)
    p1 = ruler.p1
    p2 = ruler.p2
    best = nil

    boxes.combination(2) do |a, b|
      [[a, b], [b, a]].each do |start_box, end_box|
        start_edge = nearest_edge(start_box[:box], p1)
        end_edge = nearest_edge(end_box[:box], p2)
        score = start_edge[:distance] + end_edge[:distance]

        if best.nil? || score < best[:score]
          best = {
            score: score,
            start_box: start_box,
            end_box: end_box,
            start_edge: start_edge,
            end_edge: end_edge
          }
        end
      end
    end

    unless best
      fail_dialog("Could not pair the selected ruler endpoints with the selected rectangles.")
      return nil
    end

    if best[:start_box][:layer] != best[:end_box][:layer]
      fail_dialog("The two selected rectangles are on different layers. The connector must match one material/layer.")
      return nil
    end

    width_a = best[:start_edge][:width]
    width_b = best[:end_edge][:width]
    width_tol = [layout.dbu * 5.0, [width_a.abs, width_b.abs].max * 1.0e-6].max

    if (width_a - width_b).abs > width_tol
      fail_dialog("The selected rectangle widths do not match: #{fmt(width_a)} um vs #{fmt(width_b)} um.")
      return nil
    end

    start_out = best[:start_edge][:dir]
    end_out = best[:end_edge][:dir]

    {
      start: best[:start_edge][:point],
      finish: best[:end_edge][:point],
      start_dir: start_out,
      finish_dir: [-end_out[0], -end_out[1]],
      width: 0.5 * (width_a + width_b),
      layer: best[:start_box][:layer],
      layer_info: layout.get_info(best[:start_box][:layer]),
      start_box: best[:start_box],
      end_box: best[:end_box],
      start_snap: best[:start_edge][:distance],
      end_snap: best[:end_edge][:distance]
    }
  end

  def nearest_edge(box, point)
    c = box.center
    edges = [
      { name: "left",   point: DPoint.new(box.left,  c.y), dir: [-1.0,  0.0], width: box.height },
      { name: "right",  point: DPoint.new(box.right, c.y), dir: [ 1.0,  0.0], width: box.height },
      { name: "bottom", point: DPoint.new(c.x, box.bottom), dir: [ 0.0, -1.0], width: box.width },
      { name: "top",    point: DPoint.new(c.x, box.top),    dir: [ 0.0,  1.0], width: box.width }
    ]

    edges.each { |e| e[:distance] = distance(e[:point], point) }
    edges.min_by { |e| e[:distance] }
  end

  def ask_curve_direction(connection)
    options = [
      "Automatic",
      "First bend left/up",
      "First bend right/down"
    ]
    choice = InputDialog.ask_item(
      TITLE,
      [
        "Choose the side of the FIRST bend as you travel from ruler p1/start to ruler p2/end.",
        "If the start points left-to-right: left/up makes an up-then-down S curve; right/down makes a down-then-up S curve.",
        "For vertical starts, use left/right relative to the direction of travel."
      ].join("\n"),
      options,
      0
    )
    return nil if choice.nil?

    case choice.to_s
    when options[1]
      :left
    when options[2]
      :right
    else
      :auto
    end
  end

  def ask_radii(connection, direction)
    default = default_radii_text(connection, direction)
    InputDialog.ask_string(
      TITLE,
      radii_prompt(connection, direction),
      default
    )
  end

  def radii_prompt(connection, direction)
    [
      "Centerline radii in microns, comma separated.",
      "Order is start to finish: ruler p1/start rectangle -> ruler p2/end rectangle.",
      "The prefilled values are the calculated arc-only solution when one is found.",
      "Example: 50,50 means bend 1 then bend 2 along the created path.",
      "First-bend choice: #{direction_label(direction)}."
    ].join("\n")
  end

  def direction_label(direction)
    case direction
    when :left
      "left/up from the start direction; for a left-to-right start this begins by going up, then later comes back down if needed"
    when :right
      "right/down from the start direction; for a left-to-right start this begins by going down, then later comes back up if needed"
    else
      "automatic; the solver may choose either side"
    end
  end

  def default_radii_text(connection, direction = :auto)
    automatic = automatic_default_radii_text(connection, direction)
    return automatic if automatic

    local = local_target(connection)
    width = connection[:width]
    fallback = [10.0 * width, 1.0].max

    if local[:angle].abs < 1.0e-6 && local[:x] > 1.0e-9 && local[:y].abs > 1.0e-9
      theta = 2.0 * Math.atan2(local[:y].abs, local[:x])
      s = Math.sin(theta).abs
      if s > 1.0e-9
        each_r = local[:x].abs / s / 2.0
        if each_r > width * 0.5
          return "#{fmt(each_r)},#{fmt(each_r)}"
        end
      end
    end

    fmt(fallback)
  end

  def automatic_default_radii_text(connection, direction = :auto)
    candidate_radii_sets(connection).each do |radii|
      next if radii.empty?
      next if radii.any? { |r| r <= connection[:width] * 0.5 }

      solution = solve_connection(connection, radii, direction)
      return radii.map { |r| fmt(r) }.join(",") if solution[:ok]
    end

    nil
  end

  def candidate_radii_sets(connection)
    target = local_target(connection)
    width = connection[:width]
    x = target[:x]
    y = target[:y]
    angle = target[:angle]
    span = Math.sqrt(x * x + y * y)
    useful = [[span, x.abs, y.abs].max * 0.5, width * 10.0, 1.0].max
    candidates = []

    if angle.abs > 1.0e-6
      s = Math.sin(angle)
      c = Math.cos(angle)
      if s.abs > 1.0e-9
        r = x / s
        expected_y = (angle >= 0.0 ? 1.0 : -1.0) * r.abs * (1.0 - c)
        tolerance = [1.0e-3, span * 1.0e-6].max
        candidates << [r.abs] if r > width * 0.5 && (expected_y - y).abs <= tolerance
      end
    end

    if angle.abs < 1.0e-6 && x > 1.0e-9 && y.abs > 1.0e-9
      theta = 2.0 * Math.atan2(y.abs, x)
      s = Math.sin(theta).abs
      candidates << [x.abs / s / 2.0, x.abs / s / 2.0] if s > 1.0e-9
    end

    base_values = [
      useful,
      [span / 3.0, width * 10.0, 1.0].max,
      [span / 4.0, width * 10.0, 1.0].max,
      [x.abs, y.abs, width * 10.0, 1.0].max,
      [x.abs, y.abs].max * 0.75,
      [x.abs, y.abs].max * 0.25
    ].select { |r| r && r.finite? && r > width * 0.5 }

    base_values.each do |r|
      1.upto(5) { |n| candidates << Array.new(n, r) }
    end

    unique_radius_sets(candidates)
  end

  def unique_radius_sets(sets)
    seen = {}
    sets.each_with_object([]) do |set, out|
      key = set.map { |r| (r * 1.0e6).round }.join(",")
      next if seen[key]

      seen[key] = true
      out << set
    end
  end

  def parse_radii(text)
    text.to_s.split(/[,\s;]+/).map(&:strip).reject(&:empty?).map do |part|
      Float(part)
    end.select { |v| v > 0.0 }
  rescue ArgumentError
    []
  end

  def default_npoints(radii, width)
    largest_radius = radii.max || width
    # Keep the chord error below roughly 2% of the waveguide width for the
    # largest selected radius. Basic.ARC interprets this as points per full circle.
    target_error = [width * 0.02, 0.001].max
    ratio = [[target_error / largest_radius, 1.0e-12].max, 1.0].min
    points = Math::PI / Math.acos(1.0 - ratio)
    [[points.ceil, 32].max, 1024].min
  end

  def solve_connection(connection, radii, direction = :auto)
    target = local_target(connection)
    angle_scale = [[target[:x].abs, target[:y].abs].max, radii.max || 1.0, 1.0].max
    seeds = order_seeds_by_direction(generate_seeds(radii.size, target[:angle], target[:x], target[:y]), direction)

    best = nil
    seeds.each do |seed|
      trial = improve_solution(radii, seed, target, angle_scale)
      trial[:direction_penalty] = direction_penalty(trial[:angles], direction)
      trial[:rank_score] = trial[:score] + trial[:direction_penalty]
      best = trial if best.nil? || trial[:rank_score] < best[:rank_score]
    end

    pos_tol = 1.0e-3
    angle_tol = 1.0e-4
    best[:ok] = best[:pos_error] <= pos_tol && best[:angle_error].abs <= angle_tol && best[:direction_penalty] <= 0.0
    best
  end

  def movable_end_rectangle_solution(connection, radii, direction = :auto)
    return nil unless connection[:end_box] && connection[:end_box][:direct]

    target = local_target(connection)
    start_phi = vec_angle(connection[:start_dir])
    candidates = angle_only_candidates(radii.size, target, direction)
    best = nil

    candidates.each do |angles|
      next if direction_penalty(angles, direction) > 0.0
      next if angles.all? { |a| a.abs <= MIN_ANGLE_RAD }

      x, y, phi = simulate_local(radii, angles)
      angle_error = angle_diff(phi, target[:angle]).abs
      next if angle_error > 1.0e-4

      finish = local_point_to_world(connection[:start], start_phi, x, y)
      move = DVector.new(finish.x - connection[:finish].x, finish.y - connection[:finish].y)
      score = move.x * move.x + move.y * move.y
      candidate = {
        angles: angles,
        finish: finish,
        move: move,
        move_distance: Math.sqrt(score),
        angle_error: angle_error,
        pos_error_before_move: distance(finish, connection[:finish]),
        score: score
      }
      best = candidate if best.nil? || candidate[:score] < best[:score]
    end

    best
  end

  def angle_only_candidates(n, target, direction)
    candidates = []
    seeds = order_seeds_by_direction(generate_seeds(n, target[:angle], target[:x], target[:y]), direction)
    seeds.each { |seed| candidates << normalize_angle_sum(seed, target[:angle]) }
    deterministic_angle_candidates(n, target, direction).each { |angles| candidates << angles }

    unique_seeds(candidates).map { |angles| clamp_angles(angles) }.select do |angles|
      angle_diff(angles.inject(0.0, :+), target[:angle]).abs <= 1.0e-4
    end
  end

  def deterministic_angle_candidates(n, target, direction)
    delta = target[:angle]
    return [] if n < 1

    if n == 1
      return delta.abs <= MAX_ANGLE_RAD ? [[delta]] : []
    end

    sign =
      case direction
      when :left
        1.0
      when :right
        -1.0
      else
        target[:y] >= 0.0 ? 1.0 : -1.0
      end

    base = [[2.0 * Math.atan2(target[:y].abs, [target[:x].abs, 1.0e-9].max), 15.0 * RAD].max, 120.0 * RAD].min
    candidates = []
    [base, 30.0 * RAD, 45.0 * RAD, 60.0 * RAD, 90.0 * RAD, 120.0 * RAD].each do |bend|
      angles = Array.new(n, 0.0)
      angles[0] = sign * bend
      angles[-1] = delta - angles[0]
      candidates << angles if angles.all? { |a| a.abs <= MAX_ANGLE_RAD }
    end

    candidates
  end

  def normalize_angle_sum(angles, target_sum)
    return angles if angles.empty?

    correction = angle_diff(target_sum, angles.inject(0.0, :+)) / angles.size.to_f
    clamp_angles(angles.map { |a| a + correction })
  end

  def order_seeds_by_direction(seeds, direction)
    return seeds if direction == :auto

    preferred, other = seeds.partition { |s| direction_penalty(s, direction) <= 0.0 }
    preferred + other
  end

  def direction_penalty(angles, direction)
    first = angles.find { |a| a.abs > MIN_ANGLE_RAD }
    return 0.0 if first.nil? || direction == :auto

    case direction
    when :left
      first > 0.0 ? 0.0 : 1.0e12
    when :right
      first < 0.0 ? 0.0 : 1.0e12
    else
      0.0
    end
  end

  def local_target(connection)
    t = normalize_vec(connection[:start_dir])
    n = left_normal(t)
    d = [
      connection[:finish].x - connection[:start].x,
      connection[:finish].y - connection[:start].y
    ]

    {
      x: dot(d, t),
      y: dot(d, n),
      angle: angle_diff(vec_angle(connection[:finish_dir]), vec_angle(connection[:start_dir]))
    }
  end

  def local_point_to_world(origin, phi, x, y)
    DPoint.new(
      origin.x + Math.cos(phi) * x - Math.sin(phi) * y,
      origin.y + Math.sin(phi) * x + Math.cos(phi) * y
    )
  end

  def generate_seeds(n, delta_angle, target_x, target_y)
    n = [n, 1].max
    seeds = []
    seeds << Array.new(n, delta_angle / n.to_f)

    if n == 1
      seeds << [delta_angle]
      return unique_seeds(seeds)
    end

    bend_sign = target_y >= 0.0 ? 1.0 : -1.0
    bend_angle = [[2.0 * Math.atan2(target_y.abs, [target_x.abs, 1.0e-9].max), 10.0 * RAD].max, 140.0 * RAD].min

    if n == 2
      seeds << [bend_sign * bend_angle, delta_angle - bend_sign * bend_angle]
      seeds << [-bend_sign * bend_angle, delta_angle + bend_sign * bend_angle]
    else
      s_shape = Array.new(n, 0.0)
      s_shape[0] = bend_sign * bend_angle
      s_shape[n / 2] = -2.0 * bend_sign * bend_angle
      s_shape[-1] = bend_sign * bend_angle
      correction = (delta_angle - s_shape.inject(0.0, :+)) / n.to_f
      seeds << s_shape.map { |a| a + correction }
    end

    magnitudes = [15, 30, 45, 60, 90, 120].map { |d| d * RAD }
    pattern_count = n <= 6 ? (1 << n) : 64

    pattern_count.times do |bits|
      signs = Array.new(n) { |i| ((bits >> i) & 1) == 1 ? 1.0 : -1.0 }
      magnitudes.each do |mag|
        angles = signs.map { |s| s * mag }
        correction = (delta_angle - angles.inject(0.0, :+)) / n.to_f
        seeds << angles.map { |a| a + correction }
      end
    end

    rng = Random.new(12345)
    64.times do
      angles = Array.new(n) { (rng.rand * 2.0 - 1.0) * 120.0 * RAD }
      correction = (delta_angle - angles.inject(0.0, :+)) / n.to_f
      seeds << angles.map { |a| a + correction }
    end

    unique_seeds(seeds).map { |a| clamp_angles(a) }
  end

  def unique_seeds(seeds)
    seen = {}
    seeds.each_with_object([]) do |s, out|
      key = s.map { |v| (v * 1.0e6).round }.join(",")
      next if seen[key]

      seen[key] = true
      out << s
    end
  end

  def improve_solution(radii, start_angles, target, angle_scale)
    angles = clamp_angles(start_angles)
    lambda = 1.0e-3
    best = scored_state(radii, angles, target, angle_scale)

    120.times do
      residual = residual_for(radii, angles, target, angle_scale)
      jac = jacobian(radii, angles, target, angle_scale)
      step = lm_step(jac, residual, lambda)
      break unless step

      candidate_angles = clamp_angles(angles.each_with_index.map { |a, i| a + step[i] })
      candidate = scored_state(radii, candidate_angles, target, angle_scale)

      if candidate[:score].finite? && candidate[:score] < best[:score]
        angles = candidate_angles
        best = candidate
        lambda = [lambda * 0.3, 1.0e-9].max
        break if best[:pos_error] <= 1.0e-5 && best[:angle_error].abs <= 1.0e-6
      else
        lambda = [lambda * 10.0, 1.0e9].min
      end
    end

    best
  end

  def scored_state(radii, angles, target, angle_scale)
    x, y, phi = simulate_local(radii, angles)
    pos_error = Math.sqrt((x - target[:x])**2 + (y - target[:y])**2)
    angle_error = angle_diff(phi, target[:angle]).abs
    residual = residual_for(radii, angles, target, angle_scale)
    {
      angles: angles,
      pos_error: pos_error,
      angle_error: angle_error,
      score: residual.inject(0.0) { |s, v| s + v * v }
    }
  end

  def residual_for(radii, angles, target, angle_scale)
    x, y, phi = simulate_local(radii, angles)
    [
      x - target[:x],
      y - target[:y],
      angle_diff(phi, target[:angle]) * angle_scale
    ]
  end

  def jacobian(radii, angles, target, angle_scale)
    base = residual_for(radii, angles, target, angle_scale)
    h = 1.0e-5
    rows = Array.new(3) { Array.new(angles.size, 0.0) }

    angles.each_index do |i|
      perturbed = angles.dup
      perturbed[i] += h
      r = residual_for(radii, perturbed, target, angle_scale)
      3.times { |row| rows[row][i] = (r[row] - base[row]) / h }
    end

    rows
  end

  def lm_step(jac, residual, lambda)
    m = residual.size
    n = jac.first.size
    a = Array.new(n) { Array.new(n, 0.0) }
    b = Array.new(n, 0.0)

    n.times do |i|
      m.times do |row|
        ji = jac[row][i]
        b[i] -= ji * residual[row]
        n.times { |j| a[i][j] += ji * jac[row][j] }
      end
    end

    n.times { |i| a[i][i] += lambda * ([a[i][i].abs, 1.0].max) }
    solve_linear(a, b)
  end

  def solve_linear(a, b)
    n = b.size
    m = a.map(&:dup)
    rhs = b.dup

    n.times do |i|
      pivot = (i...n).max_by { |r| m[r][i].abs }
      return nil if m[pivot][i].abs < 1.0e-14

      if pivot != i
        m[i], m[pivot] = m[pivot], m[i]
        rhs[i], rhs[pivot] = rhs[pivot], rhs[i]
      end

      piv = m[i][i]
      (i...n).each { |c| m[i][c] /= piv }
      rhs[i] /= piv

      n.times do |r|
        next if r == i

        factor = m[r][i]
        next if factor.abs < 1.0e-18

        (i...n).each { |c| m[r][c] -= factor * m[i][c] }
        rhs[r] -= factor * rhs[i]
      end
    end

    rhs
  end

  def simulate_local(radii, angles)
    x = 0.0
    y = 0.0
    phi = 0.0

    radii.each_with_index do |r, i|
      theta = angles[i]
      sign = theta >= 0.0 ? 1.0 : -1.0
      a = theta.abs
      forward = r * Math.sin(a)
      side = sign * r * (1.0 - Math.cos(a))

      x += Math.cos(phi) * forward - Math.sin(phi) * side
      y += Math.sin(phi) * forward + Math.cos(phi) * side
      phi += theta
    end

    [x, y, normalize_angle(phi)]
  end

  def ask_move_end_rectangle(connection, failed_solution, movable)
    text = [
      "No gap-free arc-only solution reaches the selected end rectangle.",
      "Best residual without moving it: #{fmt(failed_solution[:pos_error])} um and #{fmt(failed_solution[:angle_error] * DEG)} deg.",
      "",
      "The curve can be created by moving the end rectangle by:",
      "dx = #{fmt(movable[:move].x)} um, dy = #{fmt(movable[:move].y)} um",
      "Total move: #{fmt(movable[:move_distance])} um.",
      "",
      "Move the end rectangle and create the curve?"
    ].join("\n")

    MessageBox.warning(TITLE, text, MessageBox::Yes + MessageBox::No) == MessageBox::Yes
  end

  def moved_finish_connection(connection, finish)
    moved = connection.dup
    moved[:finish] = finish
    moved
  end

  def move_selected_box(box, move)
    raise "Automatic rectangle moving only supports boxes selected directly in the active cell." unless box[:direct]

    shape = box[:selection] && box[:selection].shape
    raise "Could not access the selected end rectangle shape." unless shape && shape.is_box?

    shape.transform(DTrans.new(move.x, move.y))
  end

  def place_arcs(view, cv, connection, radii, angles, npoints, move_plan = nil)
    layout = cv.layout
    cell = cv.cell
    width = connection[:width]
    start_phi = vec_angle(connection[:start_dir])
    segments, final_point, final_phi = build_segments(connection[:start], start_phi, radii, angles)

    view.transaction(move_plan ? "Move rectangle and create waveguide ARC connector" : "Create waveguide ARC connector")
    begin
      created = 0
      move_selected_box(connection[:end_box], move_plan[:move]) if move_plan

      segments.each do |seg|
        next if seg[:theta].abs < MIN_ANGLE_RAD

        inner = seg[:radius] - width * 0.5
        outer = seg[:radius] + width * 0.5
        a1, a2 = arc_pcell_angles(seg[:a1], seg[:a2])
        params = {
          "layer" => connection[:layer_info],
          "npoints" => npoints,
          "actual_radius1" => inner,
          "actual_radius2" => outer,
          "actual_start_angle" => a1,
          "actual_end_angle" => a2
        }

        arc_cell = layout.create_cell("ARC", "Basic", params)
        raise "Could not instantiate Basic.ARC PCell. Is the Basic library available?" unless arc_cell

        cell.insert(DCellInstArray.new(arc_cell, DTrans.new(seg[:center].x, seg[:center].y)))
        created += 1
      end

    ensure
      view.commit
    end

    final_pos_error = distance(final_point, connection[:finish])
    final_angle_error = angle_diff(final_phi, vec_angle(connection[:finish_dir])).abs
    message = [
      "Created #{created} Basic.ARC PCell instance#{created == 1 ? "" : "s"}.",
      "Layer: #{connection[:layer_info].to_s}",
      "Waveguide width: #{fmt(width)} um",
      "Closure residual: #{fmt(final_pos_error)} um, #{fmt(final_angle_error * DEG)} deg",
      "Endpoint snap: #{fmt(connection[:start_snap])} um, #{fmt(connection[:end_snap])} um"
    ]
    if move_plan
      message << "Moved end rectangle: dx #{fmt(move_plan[:move].x)} um, dy #{fmt(move_plan[:move].y)} um"
    end
    info_dialog(message.join("\n"))
  end

  def build_segments(start_point, start_phi, radii, angles)
    p = DPoint.new(start_point.x, start_point.y)
    phi = start_phi
    segments = []

    radii.each_with_index do |radius, i|
      theta = angles[i]
      sign = theta >= 0.0 ? 1.0 : -1.0
      left = [-Math.sin(phi), Math.cos(phi)]
      center = DPoint.new(p.x + sign * radius * left[0], p.y + sign * radius * left[1])
      a1 = Math.atan2(p.y - center.y, p.x - center.x)
      a2 = a1 + theta
      next_point = DPoint.new(center.x + radius * Math.cos(a2), center.y + radius * Math.sin(a2))

      segments << {
        center: center,
        radius: radius,
        a1: a1 * DEG,
        a2: a2 * DEG,
        theta: theta,
        p1: p,
        p2: next_point
      }

      p = next_point
      phi = normalize_angle(phi + theta)
    end

    [segments, p, phi]
  end

  def arc_pcell_angles(a1, a2)
    a1 = normalize_degrees(a1)
    a2 = normalize_degrees(a2)

    delta = (a2 - a1).abs
    if delta > 180.0
      low, high = [a1, a2].max, [a1, a2].min + 360.0
    else
      low, high = [a1, a2].min, [a1, a2].max
    end

    [low, high]
  end

  def normalize_degrees(a)
    a += 360.0 while a < 0.0
    a -= 360.0 while a >= 360.0
    a
  end

  def clamp_angles(angles)
    angles.map { |a| [[a, -MAX_ANGLE_RAD].max, MAX_ANGLE_RAD].min }
  end

  def normalize_vec(v)
    len = Math.sqrt(v[0] * v[0] + v[1] * v[1])
    raise "Zero-length direction vector" if len <= 0.0

    [v[0] / len, v[1] / len]
  end

  def left_normal(v)
    [-v[1], v[0]]
  end

  def dot(a, b)
    a[0] * b[0] + a[1] * b[1]
  end

  def vec_angle(v)
    Math.atan2(v[1], v[0])
  end

  def normalize_angle(a)
    a += 2.0 * Math::PI while a <= -Math::PI
    a -= 2.0 * Math::PI while a > Math::PI
    a
  end

  def angle_diff(a, b)
    normalize_angle(a - b)
  end

  def distance(a, b)
    Math.sqrt((a.x - b.x)**2 + (a.y - b.y)**2)
  end

  def fmt(value)
    format("%.6g", value.to_f)
  end

end

WaveguideArcConnector.run
