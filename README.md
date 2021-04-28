# ema

<img width="10%" src="https://ema.srid.ca/ema.svg">

[![Hackage](https://img.shields.io/hackage/v/ema.svg?logo=haskell)](https://hackage.haskell.org/package/ema)

Ema is a next-gen **Haskell** library for building [jamstack-style](https://jamstack.org/) static sites, with fast hot reload. See [ema.srid.ca](https://ema.srid.ca/) for further information.

The simplest Ema app looks like this:

```haskell
main :: IO ()
main = do
  let name :: Text = "Ema"
  runEmaPure $ \_ ->
    encodeUtf8 $ "<b>Hello</b>, from " <> name
```

https://user-images.githubusercontent.com/3998/116333460-789c1400-a7a1-11eb-8d28-297c349e42c6.mp4

## Hacking

Run `bin/run` (or <kbd>Ctrl+Shift+B</kbd> in VSCode). This runs the clock example (which updates every second, only to demonstrate hot reload); modify `./.ghcid` to run a different example. 

## Getting Started

Use this template: https://github.com/srid/ema-docs
