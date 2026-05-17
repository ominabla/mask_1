# Waveguide ARC Connector

This KLayout Ruby macro creates a curved waveguide connector using only `Basic.ARC`
PCell instances.

## Use

1. Draw the two orthogonal rectangular waveguide boxes.
2. Draw one ruler from the desired start rectangle toward the desired end rectangle.
3. Select the two rectangle boxes and the ruler.
4. Run `waveguide_arc_connector.rb` from KLayout's macro editor.
5. Choose the side of the first bend, or leave it automatic. For a left-to-right
   start, `First bend left/up` makes an up-then-down S curve, while
   `First bend right/down` makes a down-then-up S curve.
6. Review the automatically suggested centerline radii, then edit them if needed.
   Enter one radius per bend, comma separated.

Examples:

- `50` creates one ARC bend if the endpoints and tangents match a single bend.
- `50,50` creates a two-bend S curve when the geometry is compatible.
- `50,40,60` creates a three-ARC chain, with each bend using the listed radius.

The macro snaps the ruler endpoints to the nearest selected rectangle edge centers.
The final ARC chain uses the same layer and width as the two selected rectangles.
If the chosen radii cannot connect the selected geometry with tangent, gap-free
arcs, the macro checks whether the same curve can be created by translating the
end rectangle. When that is possible, it asks before moving the end rectangle and
creating the ARC chain. If moving the rectangle cannot fix the tangent/angle
constraint, the macro stops and reports the residual instead of placing partial
geometry.

The radius textbox is prefilled from the selected layout when the script finds a
gap-free arc-only solution. Radii are ordered from the ruler `p1`/start rectangle
to the ruler `p2`/end rectangle.
