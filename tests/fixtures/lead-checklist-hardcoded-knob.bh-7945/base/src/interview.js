// answer(question) — one interview answer from the model.
import { client } from './llm.js';
import { resolveModel } from './models.js';

export async function answer(question) {
  const res = await client.messages.create({
    model: await resolveModel('interview'),
    messages: [{ role: 'user', content: question }],
  });
  return res.content[0].text;
}
