CREATE TABLE IF NOT EXISTS "public"."trial_users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL
);


CREATE UNIQUE INDEX IF NOT EXISTS trial_users_pkey ON "public"."trial_users" USING btree (id);

ALTER TABLE "public"."trial_users" ADD CONSTRAINT "trial_users_pkey" PRIMARY KEY USING INDEX "trial_users_pkey";

CREATE UNIQUE INDEX IF NOT EXISTS trial_users_user_id_key ON "public"."trial_users" USING btree (user_id);

ALTER TABLE "public"."trial_users" ADD CONSTRAINT "trial_users_user_id_key" UNIQUE USING INDEX "trial_users_user_id_key";

ALTER TABLE "public"."trial_users" ADD CONSTRAINT "trial_users_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE not valid;

ALTER TABLE "public"."trial_users" VALIDATE CONSTRAINT "trial_users_user_id_fkey";


CREATE POLICY "Enable users to view their own data only" ON "public"."trial_users" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));

ALTER TABLE "public"."trial_users" ENABLE ROW LEVEL SECURITY;
