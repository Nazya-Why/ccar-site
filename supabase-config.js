// Підключення до Supabase. Значення беріть у Supabase → Project Settings → API Keys / Data API.
// Публічний ключ (anon / publishable) безпечно тримати на сайті: доступ до даних обмежує база.
// НІКОЛИ не вставляйте сюди service_role / secret ключ.
// Поки поля порожні, сайт працює в демо-режимі й заявки нікуди не зберігаються.
window.CCAR_SUPABASE = {
  url: "",      // напр. "https://abcdefghijkl.supabase.co"
  anonKey: ""   // напр. "sb_publishable_..." або довгий "eyJ..."
};
