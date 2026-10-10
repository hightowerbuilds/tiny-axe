// The parts of d3-force-3d the layout uses (it ships no types).

declare module "d3-force-3d" {
  export interface SimNode {
    index?: number;
    x?: number;
    y?: number;
    z?: number;
    vx?: number;
    vy?: number;
    vz?: number;
    fx?: number | null;
    fy?: number | null;
    fz?: number | null;
  }

  export interface Force<N extends SimNode> {
    (alpha: number): void;
    initialize?(nodes: N[], random: () => number, dims: number): void;
  }

  export interface Simulation<N extends SimNode> {
    tick(iterations?: number): this;
    stop(): this;
    nodes(): N[];
    nodes(nodes: N[]): this;
    numDimensions(): number;
    numDimensions(n: number): this;
    alpha(): number;
    alpha(a: number): this;
    alphaMin(): number;
    alphaMin(a: number): this;
    alphaTarget(): number;
    alphaTarget(a: number): this;
    alphaDecay(): number;
    alphaDecay(a: number): this;
    velocityDecay(): number;
    velocityDecay(a: number): this;
    force(name: string): Force<N> | undefined;
    force(name: string, force: Force<N> | null): this;
  }

  export interface LinkForce<N extends SimNode, L> extends Force<N> {
    links(links: L[]): this;
    distance(d: number | ((link: L) => number)): this;
    strength(s: number | ((link: L) => number)): this;
  }

  export interface ManyBodyForce<N extends SimNode> extends Force<N> {
    strength(s: number | ((node: N) => number)): this;
    theta(t: number): this;
    distanceMax(d: number): this;
  }

  export interface PositionForce<N extends SimNode> extends Force<N> {
    strength(s: number | ((node: N) => number)): this;
  }

  export function forceSimulation<N extends SimNode>(nodes?: N[], dims?: number): Simulation<N>;
  export function forceLink<N extends SimNode, L>(links?: L[]): LinkForce<N, L>;
  export function forceManyBody<N extends SimNode>(): ManyBodyForce<N>;
  export function forceX<N extends SimNode>(x?: number): PositionForce<N>;
  export function forceY<N extends SimNode>(y?: number): PositionForce<N>;
  export function forceZ<N extends SimNode>(z?: number): PositionForce<N>;
}
