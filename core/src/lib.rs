//! The sovereign core, in zero-dependency Rust.
//!
//! This crate carries the parts of Qwave that must not depend on a UI
//! framework: the Category-A egress allowlist and the MEM8 wave substrate
//! (the 79-byte `WaveInt` frame). Swift keeps the WebKit shell; the
//! decisions live here, behind a small C ABI that any language can call.

pub mod egress;
pub mod rational;
pub mod wave;

pub use rational::Rational;
