# MathJax Preview Sample

This file is a compact manual check for optional preview styling and MathJax runtime support.

## Checklist

- [x] GitHub-style CSS is applied
- [x] Wrapper-scoped typography looks reasonable
- [ ] Inline math renders in the paragraph below
- [ ] Display math renders below
- [ ] Fenced math block renders below

## Inline Math

Einstein's mass-energy relation is $E = mc^2$, and a quadratic equation has roots
$x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$.

## Display Math

$$
\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
$$

## Fenced Math

```math
\begin{aligned}
\nabla \cdot \mathbf{E} &= \frac{\rho}{\epsilon_0} \\
\nabla \cdot \mathbf{B} &= 0
\end{aligned}
```

## Code Block

```elisp
(message "beacon-preview mathjax sample")
```

## Table

| Item    | Expected Result       |
|---------|-----------------------|
| Inline  | Typeset in paragraph  |
| Display | Centered equation     |
| Fenced  | Typeset equation      |
| Beacons | Navigation works      |
