//! The sovereign core, in zero-dependency Rust.
//!
//! This crate carries the parts of Qwave that must not depend on a UI
//! framework: the Category-A egress allowlist, the MEM8 wave substrate
//! (the 79-byte `WaveInt` frame), the Phoenix custody protocol, the
//! `quanttern` emotional ternary code, and the `sphered` membership badge
//! witness gate. Swift keeps the WebKit shell; the decisions live here,
//! behind a small C ABI that any language can call.

pub mod badge;
pub mod egress;
pub mod markdown;
pub mod mem16;
pub mod mesh;
pub mod papers;
pub mod phoenix;
pub mod phoenix_sound;
pub mod quanttern;
pub mod rational;
pub mod salience;
pub mod telemetry;
pub mod triad;
pub mod vault;
pub mod wave;

pub use rational::Rational;
