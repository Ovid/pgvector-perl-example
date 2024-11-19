use v5.40.0;

use experimental 'class';

class AI::Vector::PgVector {
    use DBI;
    use SQL::SplitStatement;
    use Carp qw(croak);
    use AI::Vector::PgVector::Embeddings::OpenAI;

    field $verbose :param :reader = 0;
    field $dbh = DBI->connect(
        "dbi:Pg:dbname=pgvector_perl_test;host=localhost;port=55431",
        "postgres",
        "mysecretpassword",
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0
        }
    );
    field $openai = AI::Vector::PgVector::Embeddings::OpenAI->new;

    method query ($string) {
        my $embedding = $self->_vector( $openai->get_embeddings($string)->[0] );
        my $sql = <<~'SQL';
          SELECT   b.book_id,
                   b.title,
                   b.embedding <-> ? AS distance,
                   b.summary,
                   g.name            AS genre
          FROM     books b
          JOIN     book_genres g ON b.book_genre_id = g.book_genre_id
          ORDER BY distance
          LIMIT 5
          SQL
        return $dbh->selectall_hashref($sql, 'book_id', {}, $embedding);
    }

    method get_distance ($string) {
        my $embedding = $self->_vector( $openai->get_embeddings($string)->[0] );
        my $sql = "SELECT title, (embedding <-> ?) AS distance FROM books WHERE book_id = 10";
        return $dbh->selectrow_hashref($sql, {}, $embedding);
    }


    method build_db {
        if ( $self->_schema_built ) {
            say STDERR "Database already built" if $verbose;
            return
        }
        my $schema     = $self->_get_schema;
        say STDERR "Building database" if $verbose;
        my @statements = SQL::SplitStatement->new->split($schema);
        for my $statement (@statements) {
            $dbh->do($statement);
        }
        $dbh->do( $self->_get_data );
        say STDERR "Adding embeddings" if $verbose;
        $self->_add_embeddings;
    }

    method _add_embeddings () {

        # Fetch all books at once
        my $sth
          = $dbh->prepare(
            "SELECT book_id, title, summary FROM books WHERE embedding IS NULL"
          );
        $sth->execute();
        my @books = @{ $sth->fetchall_arrayref() };

        return unless @books;    # Exit if no books need processing

        # Prepare the texts for bulk embedding
        my @texts = map {"$_->[1]. $_->[2]"} @books;

        # Get all embeddings in one API call. We can also do:
        #
        #     $openai->get_embedding($string)
        #
        # However, fetching them in bulks is faster. Note that OpenAI
        # limits you to requesting a maximum of 50,000 embedding
        # inputs across all requests in the batch.
        say "Fetching embeddings for " . scalar @texts . " texts. Please be patient." if $verbose;
        my $embeddings = $openai->get_embeddings( \@texts );

        # Prepare bulk update
        my $update_sth
          = $dbh->prepare("UPDATE books SET embedding = ? WHERE book_id = ?");

        $dbh->begin_work;

        try {
            for my $i ( 0 .. $#books ) {
                my $embedding = $self->_vector( $embeddings->[$i] );
                $update_sth->execute( $embedding, $books[$i][0] );
            }
            $dbh->commit;
        }
        catch ($error) {
            $dbh->rollback;
            croak "Failed to update embeddings: $error";
        }
    }

    method _vector ($embedding) {
        return sprintf '[%s]', join ',', $embedding->@*;
    }

    method rebuild_db {

        # Drop tables in correct order (books depends on book_genres)
        $dbh->do("DROP TABLE IF EXISTS books CASCADE") or croak $dbh->errstr;
        $dbh->do("DROP TABLE IF EXISTS book_genres CASCADE")
          or croak $dbh->errstr;

        $dbh->do("DROP FUNCTION IF EXISTS update_updated_at_column CASCADE")
          or croak $dbh->errstr;

        $self->build_db;
    }

    method _schema_built () {

        # Naïve check if tables already exist
        my $sth = $dbh->prepare(<<~'SQL');
          SELECT EXISTS (
              SELECT FROM information_schema.tables 
              WHERE table_name = 'books'
          )
          SQL
        $sth->execute();
        my ($exists) = $sth->fetchrow_array();
        return $exists;
    }

    method _get_schema () {
        return <<~'SQL';
        CREATE EXTENSION IF NOT EXISTS vector;

        CREATE TABLE book_genres (
            book_genre_id    SERIAL PRIMARY KEY,
            name VARCHAR(50) NOT NULL UNIQUE,
            created_at       TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE TABLE books (
            book_id       SERIAL PRIMARY KEY,
            title         VARCHAR(255) NOT NULL,
            summary       TEXT NOT NULL CHECK (LENGTH(summary) <= 4000),
            embedding     vector(1536), -- here's the magic!
            book_genre_id INTEGER NOT NULL REFERENCES book_genres(book_genre_id),
            created_at    TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            updated_at    TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );
        
        CREATE INDEX idx_books_genre_id ON books(book_genre_id);
        
        CREATE OR REPLACE FUNCTION update_updated_at_column()
        RETURNS TRIGGER AS $$
        BEGIN
            NEW.updated_at = CURRENT_TIMESTAMP;
            RETURN NEW;
        END;
        $$ language 'plpgsql';
        
        CREATE TRIGGER update_books_updated_at
            BEFORE UPDATE ON books
            FOR EACH ROW
            EXECUTE FUNCTION update_updated_at_column();
        
        INSERT INTO book_genres (name) VALUES
            ('Fiction'),
            ('Non-Fiction'),
            ('Science Fiction'),
            ('Mystery'),
            ('Fantasy'),
            ('Horror'); 
        SQL
    }

    method _get_data () {
        return <<~'SQL';
          INSERT INTO books (title, summary, book_genre_id, embedding) VALUES
              ('Amara''s Amazing Hair Day', 
              'When Amara wakes up to find her beautiful natural hair has magical powers, she learns to embrace her uniqueness while helping others see the beauty in their own hair. Each protective style she creates grants her a different superpower!',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Fantasy'),
              NULL),
          
              ('The Lunar New Year Cat Parade', 
              'Mei''s cat Bao refuses to miss out on the Lunar New Year celebrations. As Mei prepares traditional foods with her grandmother, Bao secretly organizes all the neighborhood cats for a spectacular parade that brings the whole community together.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Fiction'),
              NULL),
          
              ('Los Tres Gatos y La Piñata', 
              'Three clever cats living in Mexico City work together to protect a beautiful birthday piñata from a mischievous group of mice. Through teamwork and ingenuity, they learn about friendship while experiencing the joy of a traditional celebration.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Fiction'),
              NULL),
          
              ('The Sacred Eagle Feather', 
              'During a powwow celebration, young Jamie from the Lakota tribe learns about the significance of eagle feathers in her culture when she''s tasked with protecting a sacred feather. With guidance from her grandmother, she discovers the deep connection between tradition and respect for nature.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Non-Fiction'),
              NULL),
          
              ('Robot Ramadan', 
              'When young inventor Zahra creates a robot to help her family prepare iftar meals during Ramadan, hilarious chaos ensues. But through the mishaps, she learns the true meaning of the holy month is about community and sharing.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Science Fiction'),
              NULL),
          
              ('The Hidden Temple of Books', 
              'Deepa discovers an ancient temple in Mumbai filled with magical books containing stories from across India. With her magical tabby cat guide, she must protect the sacred stories from being forgotten.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Fantasy'),
              NULL),
          
              ('The Great Djembe Detective', 
              'Kofi uses his knowledge of West African drum rhythms to solve mysteries in his neighborhood. When instruments start disappearing before the big cultural festival, he must follow the beats to find the truth.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Mystery'),
              NULL),
          
              ('Abuela''s Time Machine', 
              'Carmen and her grandmother use a magical molcajete to travel through time, witnessing key moments in Mexican-American history while making traditional recipes that hold special meaning to their family.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Science Fiction'),
              NULL),
          
              ('The Night Market Ghost', 
              'During a visit to Singapore''s famous night market, Jun meets a friendly ghost who introduces him to the stories behind traditional foods. Together they help market vendors share their cultural heritage with a new generation.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Horror'),
              NULL),
          
              ('The Diwali Science Fair', 
              'Priya combines her love of science with Diwali celebrations to create an amazing light display for her school''s science fair. Her project teaches everyone about both the festival of lights and solar power.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Non-Fiction'),
              NULL),
          
              ('Dragons Love Dim Sum', 
              'In a magical version of San Francisco''s Chinatown, a young chef discovers that the city''s dragons disguise themselves as humans to enjoy her family''s dim sum restaurant. She must keep their secret while learning to cook dishes that satisfy both human and dragon customers.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Fantasy'),
              NULL),
          
              ('The Brooklyn Brownstone Mystery', 
              'When strange noises come from Ms. Thompson''s brownstone, the neighborhood kids assume it''s haunted. But Zara and her detective cat Mr. Midnight discover something unexpected about their community''s history.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Mystery'),
              NULL),
          
              ('The Sari that Touched the Stars', 
              'Inspired by astronaut Kalpana Chawla, young Aisha dreams of space exploration. She creates a spacesuit from her mother''s old sari and ends up on an incredible adventure beyond Earth.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Science Fiction'),
              NULL),
          
              ('The Box of Caribbean Monsters', 
              'When Aiden accidentally opens his grandmother''s old box, he releases friendly versions of Caribbean folklore creatures. With help from local elders, he learns about his heritage while trying to get the creatures back home.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Horror'),
              NULL),
          
              ('The Underground Railroad Code Breakers', 
              'Based on true historical events, follow two brave kids who use quilts and songs to help guide people to freedom, teaching readers about the ingenious ways that escaped slaves communicated along the Underground Railroad.',
              (SELECT book_genre_id FROM book_genres WHERE name = 'Mystery'),
              NULL);
        SQL
    }
}
