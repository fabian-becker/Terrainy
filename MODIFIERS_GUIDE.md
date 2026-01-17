# Terrain Modifiers Guide

All terrain feature nodes in Terrainy now support modifiers that can be applied to adjust the appearance of generated terrain.

## Smoothing

Smoothing reduces the spikiness and roughness of terrain, creating more natural-looking landscapes.

### Smoothing Modes

- **None**: No smoothing applied (default)
- **Light**: Subtle smoothing, good for reducing sharp edges while maintaining detail
  - Uses 4 sample points
  - Radius: 50% of smoothing_radius
- **Medium**: Balanced smoothing for most use cases
  - Uses 8 sample points
  - Radius: 100% of smoothing_radius
- **Heavy**: Strong smoothing for very rounded, soft terrain
  - Uses 12 sample points
  - Radius: 150% of smoothing_radius

### Parameters

- **Smoothing Radius** (0.5 - 10.0): Controls the area of influence for smoothing
  - Smaller values: More localized smoothing, preserves detail
  - Larger values: Broader smoothing, creates gentler slopes

### Recommended Settings

**For Mountain Ranges:**
- Smoothing: MEDIUM or HEAVY
- Smoothing Radius: 2.0 - 4.0

**For Noise Terrain:**
- Smoothing: LIGHT or MEDIUM
- Smoothing Radius: 1.5 - 3.0

**For Craters/Hills:**
- Smoothing: LIGHT
- Smoothing Radius: 1.0 - 2.0

## Terracing

Creates stepped, layered terrain effects similar to natural geological formations or agricultural terraces.

### Parameters

- **Enable Terracing**: Turn terracing effect on/off
- **Terrace Levels** (2-20): Number of distinct height levels
  - Lower values (2-5): Dramatic, bold steps
  - Medium values (6-10): Natural-looking layers
  - Higher values (11-20): Subtle layering effect
- **Terrace Smoothness** (0.0-1.0): Transition between levels
  - 0.0: Hard, sharp edges between steps
  - 0.5: Moderate transition
  - 1.0: Very smooth, gradual transitions

### Creative Uses

- **Mountains**: 8-12 levels with 0.2 smoothness for stratified peaks
- **Mesas**: 3-5 levels with 0.0 smoothness for flat-topped formations
- **Alien Terrain**: 15-20 levels with 0.8 smoothness for unusual landscapes

## Height Clamping

Limits the minimum and/or maximum height values of a terrain feature.

### Parameters

- **Enable Min Clamp**: Activate minimum height limiting
- **Min Height**: Lowest allowed height value
- **Enable Max Clamp**: Activate maximum height limiting
- **Max Height**: Highest allowed height value

### Use Cases

- **Plateaus**: Set max clamp to create flat-topped features
- **Underwater Terrain**: Use min clamp to prevent terrain from rising above sea level
- **Controlled Elevation**: Prevent extreme height variations in specific features

## Performance Considerations

### Smoothing Performance

- Smoothing uses sample-based averaging and includes caching
- Cache is organized by grid cells to improve hit rates
- Cache is automatically cleared when smoothing parameters change
- HEAVY smoothing uses more samples and may impact performance on very large terrains

### Tips for Best Performance

1. Use the lowest smoothing level that achieves your desired result
2. Smaller smoothing_radius values are faster
3. Smoothing cache helps with repeated terrain generation
4. Combine with TerrainComposer's optimization settings for best results

## Example Workflow

### Fixing Spiky Mountains

1. Select your MountainRangeNode in the scene tree
2. In the Inspector, expand the "Modifiers" section
3. Set **Smoothing** to "Medium"
4. Set **Smoothing Radius** to 3.0
5. The terrain will automatically regenerate with smoother peaks

### Creating Layered Canyon Walls

1. Select your CanyonNode
2. Enable **Terracing**
3. Set **Terrace Levels** to 8
4. Set **Terrace Smoothness** to 0.3
5. Optionally add light smoothing for softer edges

### Combining Modifiers

You can use multiple modifiers together:
- Smoothing + Terracing: Creates smooth, flowing layers
- Smoothing + Height Clamping: Smooth terrain with controlled elevation
- All Three: Maximum control over terrain appearance

The modifiers are applied in this order:
1. Smoothing
2. Terracing
3. Height Clamping
