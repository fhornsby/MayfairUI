module mayfair.properties;

/*
    Properties and bindings: values that can be watched, and kept in step with each other.
    JavaFX's javafx.beans. Every setting on a widget is a property, so anything a widget shows can
    be bound to anything else, and animated with a Timeline's KeyValues.
*/
public import mayfair.properties.observable;
public import mayfair.properties.property;
public import mayfair.properties.binding;
public import mayfair.properties.declare;
