# kdbx-modules

A collection of custom modules for [KDB-X](https://code.kx.com/kdb-x/).

## Modules

| Module | Description |
|--------|-------------|
| [di.simtick](di/simtick/) | Realistic intraday tick data simulator with configurable market microstructure |

## Installation

Add this repository to your `QPATH`:

```bash
export QPATH=$QPATH:/path/to/kdbx-modules
```

Then load any module:

```q
q)simtick:use`di.simtick
```

## Creating New Modules

Each module should follow the [KDB-X module framework](https://code.kx.com/kdb-x/modules/) and include:

- `init.q` — Module code
- `test.csv` — Unit tests (k4unit format)
- `README.md` — Documentation

## License

MIT
