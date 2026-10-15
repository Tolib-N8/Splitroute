import React from "react";
import { Composition } from "remotion";
import { Reel, REEL_FRAMES } from "./Reel";

export const Root: React.FC = () => (
  <Composition id="Reel" component={Reel} durationInFrames={REEL_FRAMES} fps={30} width={1080} height={1920} />
);
