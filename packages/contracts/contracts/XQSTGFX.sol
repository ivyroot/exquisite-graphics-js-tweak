// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import './interfaces/IGraphics.sol';
import './interfaces/IRenderContext.sol';
import {XQSTHelpers as helpers} from './XQSTHelpers.sol';
import {XQSTDecode as decode} from './XQSTDecode.sol';
import {XQSTValidate as v} from './XQSTValidate.sol';
import '@divergencetech/ethier/contracts/utils/DynamicBuffer.sol';

contract XQSTGFX is IGraphics, IRenderContext {
  using DynamicBuffer for bytes;

  enum DrawType {
    SVG,
    RECTS
  }

  /// @notice Draw an SVG from the provided data
  /// @param data Binary data in the .xqst format.
  /// @return string the <svg>
  function draw(bytes memory data) public pure returns (string memory) {
    return _draw(data, DrawType.SVG, true);
  }

  /// @notice Draw an SVG from the provided data. No validation
  /// @param data Binary data in the .xqst format.
  /// @return string the <svg>
  function drawUnsafe(bytes memory data) public pure returns (string memory) {
    return _draw(data, DrawType.SVG, false);
  }

  /// @notice Draw the <rect> elements of an SVG from the data
  /// @param data Binary data in the .xqst format.
  /// @return string the <rect> elements
  function drawRects(bytes memory data) public pure returns (string memory) {
    return _draw(data, DrawType.RECTS, true);
  }

  /// @notice Draw the <rect> elements of an SVG from the data. No validation
  /// @param data Binary data in the .xqst format.
  /// @return string the <rect> elements
  function drawRectsUnsafe(bytes memory data)
    public
    pure
    returns (string memory)
  {
    return _draw(data, DrawType.RECTS, false);
  }

  /// @notice validates if the given data is a valid .xqst file
  /// @param data Binary data in the .xqst format.
  /// @return bool true if the data is valid
  function validate(bytes memory data) public pure returns (bool) {
    return v._validate(data);
  }

  // Check if the header of some data is an XQST Graphics Compatible file
  /// @notice validates the header for some data is a valid .xqst header
  /// @param data Binary data in the .xqst format.
  /// @return bool true if the header is valid
  function validateHeader(bytes memory data) public pure returns (bool) {
    return v._validateHeader(decode._decodeHeader(data));
  }

  /// @notice Decodes the header from a binary .xqst blob
  /// @param data Binary data in the .xqst format.
  /// @return Header the decoded header
  function decodeHeader(bytes memory data) public pure returns (Header memory) {
    return decode._decodeHeader(data);
  }

  /// @notice Decodes the palette from a binary .xqst blob
  /// @param data Binary data in the .xqst format.
  /// @return bytes8[] the decoded palette
  function decodePalette(bytes memory data)
    public
    pure
    returns (string[] memory)
  {
    return decode._decodePalette(data, decode._decodeHeader(data));
  }

  /// @notice Decodes all of the data needed to draw an SVG from the .xqst file
  /// @param data Binary data in the .xqst format.
  /// @return ctx The Render Context containing all of the decoded data
  function decodeData(bytes memory data)
    public
    pure
    returns (Context memory ctx)
  {
    _init(ctx, data, true);
  }

  /// Initializes the Render Context from the given data
  /// @param ctx Render Context to initialize
  /// @param data Binary data in the .xqst format.
  /// @param safe bool whether to validate the data
  function _init(
    Context memory ctx,
    bytes memory data,
    bool safe
  ) private pure {
    ctx.header = decode._decodeHeader(data);
    if (safe) {
      v._validateHeader(ctx.header);
      v._validateDataLength(ctx.header, data);
    }

    ctx.palette = decode._decodePalette(data, ctx.header);
    ctx.pixelColorLUT = decode._getPixelColorLUT(data, ctx.header);
    ctx.numberLUT = helpers._getNumberLUT(ctx.header);
  }

  /// Draws the SVG or <rect> elements from the given data
  /// @param data Binary data in the .xqst format.
  /// @param t The SVG or Rectangles to draw
  /// @param safe bool whether to validate the data
  function _draw(
    bytes memory data,
    DrawType t,
    bool safe
  ) private pure returns (string memory) {
    Context memory ctx;
    bytes memory buffer = DynamicBuffer.allocate(2**18);

    _init(ctx, data, safe);

    t == DrawType.RECTS ? _writeSVGRects(ctx, buffer) : _writeSVG(ctx, buffer);

    return string(buffer);
  }

  /// Writes the entire SVG to the given buffer
  /// @param ctx The Render Context
  /// @param buffer The buffer to write the SVG to
  function _writeSVG(Context memory ctx, bytes memory buffer) private pure {
    _writeSVGHeader(ctx, buffer);
    _writeSVGRects(ctx, buffer);
    buffer.appendSafe('</svg>');
  }

  /// Writes the SVG header to the given buffer
  /// @param ctx The Render Context
  /// @param buffer The buffer to write the SVG header to
  function _writeSVGHeader(Context memory ctx, bytes memory buffer)
    internal
    pure
  {
    uint256 scale = uint256(ctx.header.scale);
    // default scale to >=512px.
    if (scale == 0) {
      scale =
        512 /
        (
          ctx.header.width > ctx.header.height
            ? ctx.header.width
            : ctx.header.height
        ) +
        1;
    }

    buffer.appendSafe(
      abi.encodePacked(
        '<svg xmlns="http://www.w3.org/2000/svg" shape-rendering="crispEdges" version="1.1" viewBox="0 0 ',
        helpers.toBytes(ctx.header.width),
        ' ',
        helpers.toBytes(ctx.header.height),
        '" width="',
        helpers.toBytes(ctx.header.width * scale),
        '" height="',
        helpers.toBytes(ctx.header.height * scale),
        '">'
      )
    );
  }

  /// Writes the SVG <rect> elements to the given buffer
  /// @param ctx The Render Context
  /// @param buffer The buffer to write the SVG <rect> elements to
  function _writeSVGRects(Context memory ctx, bytes memory buffer)
    internal
    pure
  {
    uint256 colorIndex;
    uint256 c;
    uint256 pixelNum;

    // create a rect that fills the entirety of the svg as the background
    if (ctx.header.hasBackground) {
      buffer.appendSafe(
        abi.encodePacked(
          '"<rect fill="#',
          ctx.palette[ctx.header.backgroundColorIndex],
          '" height="',
          ctx.numberLUT[ctx.header.height],
          '" width="',
          ctx.numberLUT[ctx.header.width],
          '"/>'
        )
      );
    }

    // Write every pixel into the buffer
    while (pixelNum < ctx.header.totalPixels) {
      colorIndex = ctx.pixelColorLUT[pixelNum];

      // Check if we need to write a new rect to the buffer at all
      if (helpers._canSkipPixel(ctx, colorIndex)) {
        pixelNum++;
        continue;
      }

      // Calculate the width of a continuous rect with the same color
      c = 1;
      while ((pixelNum + c) % ctx.header.width != 0) {
        if (colorIndex == ctx.pixelColorLUT[pixelNum + c]) {
          c++;
        } else break;
      }

      buffer.appendSafe(
        abi.encodePacked(
          '<rect fill="#',
          ctx.palette[colorIndex],
          '" x="',
          ctx.numberLUT[pixelNum % ctx.header.width],
          '" y="',
          ctx.numberLUT[pixelNum / ctx.header.width],
          '" height="1" width="',
          ctx.numberLUT[c],
          '"/>'
        )
      );

      unchecked {
        pixelNum += c;
      }
    }
  }
}
