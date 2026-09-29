import type { CharacterDefinition } from '../types';
import { Blaze } from './blaze';
import { Volt } from './volt';
import { Titan } from './titan';
import { Shadow } from './shadow';

/**
 * Playable roster. To add a fifth fighter, create a CharacterDefinition in
 * this folder and append it here — the selection screen, HUD, AI and combat
 * systems pick it up automatically (see README).
 */
export const CHARACTERS: CharacterDefinition[] = [Blaze, Volt, Titan, Shadow];

export function getCharacter(id: string): CharacterDefinition | undefined {
  return CHARACTERS.find((c) => c.id === id);
}
