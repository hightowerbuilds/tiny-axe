defmodule TinyAxe.TUI.Welcome.Render do
  @moduledoc """
  Draws one frame of the welcome axe (`TinyAxe.TUI.Welcome`), at compile
  time: a double-bit axe as a signed-distance field, ray-cast cell by cell
  and lit from the front left.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}

  @green {126, 211, 115}
  @orange {245, 163, 78}
  @steel {205, 220, 225}

  @cols 44
  @rows 13
  @frame_count 48

  # The picture: cells are about twice as tall as wide, so a column is half
  # a unit and a row a whole one.
  @cell_w 0.31
  @cell_h 0.62
  # Where the ray starts and stops, and how finely it looks.
  @near -4.0
  @far 4.0
  @step 0.06
  @ramp ~c" .,:;-=+*#%@"

  def cols, do: @cols
  def rows, do: @rows
  def frame_count, do: @frame_count

  ## The axe, in its own space: the handle up the y axis, the head across x.

  # A double-bit head: a block around the eye that flares into two curved
  # bits, each ground thin towards its edge.
  defp head(x, y, z) do
    ax = abs(x)
    t = min(ax / 3.9, 1.0)
    # The bits sweep out and curve back in at the top and bottom corners.
    flare = 0.95 * t * t
    top = 2.85 + flare
    bottom = 0.95 - flare
    # The blade's thickness: full at the eye, a fine edge at the bit.
    thick = 0.08 + 0.34 * (1 - t) * (1 - t)
    # Each bit's edge is a shallow arc, fullest at the middle of the head.
    mid = (y - 1.9) / 1.9
    dx = ax - (3.9 - 0.6 * mid * mid)
    dy = max(bottom - y, y - top)
    dz = abs(z) - thick
    max(dx, max(dy, dz))
  end

  # A round handle, swelling a little at the grip, with a knob at the end.
  defp handle(x, y, z) do
    r = :math.sqrt(x * x + z * z)
    radius = 0.52 + 0.1 * max(0.0, -y / 3.4)
    body = max(r - radius, max(-3.4 - y, y - 3.2))
    knob = :math.sqrt(x * x + (y + 3.3) * (y + 3.3) + z * z) - 0.7
    min(body, knob)
  end

  # Which part is nearest, and how far: {distance, :head | :handle}.
  defp sdf(x, y, z) do
    h = head(x, y, z)
    s = handle(x, y, z)
    if h < s, do: {h, :head}, else: {s, :handle}
  end

  ## Turning and lighting

  # The axe spins about its handle and nods a little, with a fixed lean so
  # the top of the head shows.
  defp rotation(frame) do
    spin = frame * 2 * :math.pi() / @frame_count
    nod = 0.18 * :math.sin(2 * spin)
    {spin, 0.42 + nod}
  end

  # A point in view space, taken back into the axe's own space: undo the
  # lean (about x), then the spin (about y).
  defp to_model({x, y, z}, {spin, lean}) do
    cl = :math.cos(lean)
    sl = :math.sin(lean)
    y1 = y * cl - z * sl
    z1 = y * sl + z * cl
    cs = :math.cos(spin)
    ss = :math.sin(spin)
    {x * cs - z1 * ss, y1, x * ss + z1 * cs}
  end

  defp distance(point, rot) do
    {x, y, z} = to_model(point, rot)
    sdf(x, y, z)
  end

  # The surface normal in view space, from the field's slope.
  defp normal({x, y, z}, rot) do
    e = 0.02
    {dx, _} = distance({x + e, y, z}, rot)
    {dx2, _} = distance({x - e, y, z}, rot)
    {dy, _} = distance({x, y + e, z}, rot)
    {dy2, _} = distance({x, y - e, z}, rot)
    {dz, _} = distance({x, y, z + e}, rot)
    {dz2, _} = distance({x, y, z - e}, rot)
    unit({dx - dx2, dy - dy2, dz - dz2})
  end

  defp unit({x, y, z}) do
    n = :math.sqrt(x * x + y * y + z * z)
    if n == 0, do: {0.0, 0.0, 1.0}, else: {x / n, y / n, z / n}
  end

  defp dot({a, b, c}, {d, e, f}), do: a * d + b * e + c * f

  # Light from above, to the left and from behind the viewer (who looks
  # in along +z, from the near side).
  @light_n (fn {x, y, z} ->
              n = :math.sqrt(x * x + y * y + z * z)
              {x / n, y / n, z / n}
            end).({-0.5, 0.65, -0.6})

  # Walks the ray in from the front until it enters the axe (or gives up).
  defp cast(x, y, rot, z \\ @near) do
    if z > @far do
      nil
    else
      {d, part} = distance({x, y, z}, rot)

      if d < 0.01,
        do: {{x, y, z}, part},
        else: cast(x, y, rot, z + max(d * 0.5, @step))
    end
  end

  # What a cell shows: its character and colour, or nothing.
  defp cell(col, row, rot) do
    x = (col - (@cols - 1) / 2) * @cell_w
    y = -(row - (@rows - 1) / 2) * @cell_h

    case cast(x, y, rot) do
      nil ->
        {?\s, nil}

      {point, part} ->
        n = normal(point, rot)
        diffuse = max(dot(n, @light_n), 0.0)
        # The half-way vector between the light and the viewer, for the glint.
        {lx, ly, lz} = @light_n
        half = unit({lx, ly, lz - 1.0})
        gloss = :math.pow(max(dot(n, half), 0.0), if(part == :head, do: 24, else: 6))

        {base, light} =
          case part do
            :head ->
              {if(edge?(point, rot), do: @green, else: @steel), 0.2 + 0.6 * diffuse + 0.7 * gloss}

            :handle ->
              {@orange, 0.25 + 0.7 * diffuse + 0.3 * gloss}
          end

        light = min(light, 1.0)
        {r, g, b} = base
        shade = fn c -> round(c * (0.35 + 0.65 * light)) end

        {Enum.at(@ramp, round(light * (length(@ramp) - 1))),
         {:rgb, shade.(r), shade.(g), shade.(b)}}
    end
  end

  # The bits, where the head is ground thin, take the brand's green.
  defp edge?(point, rot) do
    {x, _y, _z} = to_model(point, rot)
    abs(x) > 3.1
  end

  @doc "One frame as lines of spans, runs of a colour joined."
  def frame(index) do
    rot = rotation(index)

    for row <- 0..(@rows - 1) do
      0..(@cols - 1)
      |> Enum.map(&cell(&1, row, rot))
      |> Enum.chunk_by(&elem(&1, 1))
      |> Enum.map(fn [{_, color} | _] = run ->
        Span.new(List.to_string(Enum.map(run, &elem(&1, 0))),
          style: %Style{fg: color, modifiers: [:bold]}
        )
      end)
      |> Line.new()
    end
  end
end
