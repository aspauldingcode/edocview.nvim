# edocview smoke test

Inline math: $e^{i\pi} + 1 = 0$.

Display math:

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

Local image:

![edocview image](markdown-image.svg)

```mermaid
flowchart LR
    Source --> Preview
```

```dotviz
digraph G {
    edit -> render -> display;
}
```
