import DiaryPreview from "./diary-preview";
import DiaryReader from "./diary-reader";

export default async function Home({ searchParams }: PageProps<"/">) {
  if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY) {
    return <DiaryPreview />;
  }
  const params = await searchParams;
  return <DiaryReader groupId={typeof params.group === "string" ? params.group : undefined}
    entryId={typeof params.entry === "string" ? params.entry : undefined} writing={params.write === "1" && !params.entry} />;
}
