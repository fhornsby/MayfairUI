module mayfair.animation;

public import mayfair.animation.animation;
public import mayfair.animation.transition;
public import mayfair.animation.timeline;
public import mayfair.animation.interpolator;

// Durations are core.time's, so `250.msecs` should work wherever animations do
public import core.time : Duration, msecs, seconds;
